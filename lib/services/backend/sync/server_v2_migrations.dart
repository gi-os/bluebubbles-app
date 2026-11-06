import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/actions/attachment_actions.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';

/// Fills in data that servers older than v2 never sent, for messages already synced from them.
/// Sync never refetches old messages, so this has to ask the server again.
class ServerV2Migrations {
  /// Bump when adding a backfill, so clients that finished the earlier ones run again.
  static const int version = 3;

  /// Run on startup: once the server is known to be v2, and on each launch until a pass gets through.
  static Future<void> runOnce() async {
    if (PrefsSvc.database.getServerV2MigrationsVersion() >= version || !SettingsSvc.serverDetails.isV2Server) return;
    if (await run() != null) await PrefsSvc.database.setServerV2MigrationsVersion(version);
  }

  static Future<int?>? _running;

  /// Returns how many messages were updated, or null if a request failed or the server isn't v2. Joins a pass that's
  /// already running rather than starting a second.
  static Future<int?> run() => _running ??= _run().whenComplete(() => _running = null);

  static Future<int?> _run() async {
    if (!SettingsSvc.serverDetails.isV2Server) return null;
    final emoji = await _backfillTapbackEmoji();
    if (emoji == null) return null;
    final genmoji = await _backfillGenmoji();
    if (genmoji == null) return null;
    final stickers = await _backfillStickerPlacement();
    if (stickers == null) return null;
    return emoji + genmoji + stickers;
  }

  /// Fills in `stickerPlacement` on placed stickers synced before the client kept it.
  static Future<int?> _backfillStickerPlacement() async {
    final query =
        Database.messages.query(Message_.associatedMessageType.equals("sticker").and(Message_.guid.notNull())).build();
    final missing = (await runAsync(() => query.find()))
        .where(_isOnServer)
        .where((m) => m.dbAttachments.any((a) => a.stickerPlacement == null))
        .toList();
    query.close();

    int filled = 0;
    for (final sticker in missing) {
      try {
        final response = await HttpSvc.message.fetchOne(sticker.guid!, withQuery: "attachment");
        final remote = (((response.data['data'] as Map?)?['attachments'] as List?) ?? const [])
            .whereType<Map>()
            .map((a) => Attachment.fromMap(a.cast<String, dynamic>()))
            .toList();
        AttachmentActions.adoptRekeyedGuids(remote);
        final current = Database.messages.get(sticker.id!);
        if (current == null) continue;
        var changed = false;
        for (final a in current.dbAttachments) {
          final placement = remote.firstWhereOrNull((r) => r.guid == a.guid)?.stickerPlacement;
          if (a.stickerPlacement != null || placement == null) continue;
          a.stickerPlacement = placement;
          Database.attachments.put(a);
          changed = true;
        }
        if (!changed) continue;
        filled++;
        final chatGuid = current.chat.target?.guid;
        if (chatGuid != null && current.associatedMessageGuid != null) {
          maybeFindMessagesSvc(chatGuid)
              ?.getMessageStateIfExists(current.associatedMessageGuid!)
              ?.addAssociatedMessageInternal(current);
        }
      } catch (e, s) {
        if (e is Response && '${e.data}'.contains('Message does not exist!')) continue;
        Logger.warn("Failed to backfill the placement of sticker ${sticker.guid}",
            error: e, trace: s, tag: "ServerV2Migrations");
        return null;
      }
    }
    return filled;
  }

  /// Re-fetches attributed bodies saved before the client kept the Genmoji marker, `__kIMEmojiImageAttributeName`.
  static Future<int?> _backfillGenmoji() async {
    final query = Database.messages
        .query(Message_.dbAttributedBody.contains("__kIMFileTransferGUIDAttributeName").and(Message_.guid.notNull()))
        .build();
    final candidates = (await runAsync(() => query.find())).where(_isOnServer).where((message) {
      final body = message.attributedBody.firstOrNull;
      if (body == null || body.runs.any((r) => r.isEmojiImage)) return false;
      final textParts = body.runs.where((r) => !r.isAttachment).map((r) => r.attributes?.messagePart).toSet();
      return body.runs.any((r) => r.isAttachment && textParts.contains(r.attributes?.messagePart));
    }).toList();
    query.close();

    int filled = 0;
    for (final message in candidates) {
      try {
        final response = await HttpSvc.message.fetchOne(message.guid!, withQuery: "attributedBody");
        final data = response.data['data'];
        if (data is! Map) continue;
        final fresh = Message.fromMap(Map<String, dynamic>.from(data)).attributedBody;
        if (!fresh.any((b) => b.runs.any((r) => r.isEmojiImage))) continue;

        final current = Database.messages.get(message.id!);
        if (current == null) continue;
        current.attributedBody = fresh;
        Database.messages.put(current);
        filled++;
      } catch (e, s) {
        if (e is Response && '${e.data}'.contains('Message does not exist!')) continue;
        Logger.warn("Failed to backfill the Genmoji of ${message.guid}", error: e, trace: s, tag: "ServerV2Migrations");
        return null;
      }
    }
    return filled;
  }

  /// Whether [message] is on the server, rather than a local one still sending or that failed to.
  static bool _isOnServer(Message message) => !message.guid!.startsWith("temp") && !message.guid!.startsWith("error");

  static Future<int?> _backfillTapbackEmoji() async {
    final query = Database.messages
        .query(Message_.associatedMessageType
            .oneOf([ReactionTypes.EMOJI, ReactionTypes.REMOVED_EMOJI])
            .and(Message_.associatedMessageEmoji.isNull())
            .and(Message_.guid.notNull()))
        .build();
    final missing = (await runAsync(() => query.find())).where(_isOnServer).toList();
    query.close();

    int filled = 0;
    for (final reaction in missing) {
      try {
        final response = await HttpSvc.message.fetchOne(reaction.guid!);
        // The server leaves the key out when chat.db has no emoji for this one, so skip it
        final emoji = (response.data['data'] as Map?)?['associatedMessageEmoji'] as String?;
        if (emoji == null) continue;

        // Re-read, so anything saved to it while the request was out isn't overwritten
        final current = Database.messages.get(reaction.id!);
        if (current == null) continue;
        current.associatedMessageEmoji = emoji;
        Database.messages.put(current);
        filled++;
        final chatGuid = current.chat.target?.guid;
        if (chatGuid != null && current.associatedMessageGuid != null) {
          maybeFindMessagesSvc(chatGuid)
              ?.getMessageStateIfExists(current.associatedMessageGuid!)
              ?.addAssociatedMessageInternal(current);
        }
      } catch (e, s) {
        // Tunnels and proxies can also return a 404, so only the server's own error means the message is gone.
        // Anything else retries next launch; stop now rather than wait out a timeout per message.
        if (e is Response && '${e.data}'.contains('Message does not exist!')) continue;
        Logger.warn("Failed to backfill emoji for tapback ${reaction.guid}",
            error: e, trace: s, tag: "ServerV2Migrations");
        return null;
      }
    }
    return filled;
  }
}

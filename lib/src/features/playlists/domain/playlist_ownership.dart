import 'package:navis/src/database/navis_database.dart';

/// A server playlist with a known owner is editable only by that owner; with
/// the viewer unknown (config not loaded) it is not, so it never offers edits
/// the server will refuse.
bool canEditPlaylist(PlaylistsTableData p, String? me) =>
    p.isLocal ||
    (p.readOnly != true &&
        (p.owner == null ||
            (me != null && p.owner!.toLowerCase() == me.toLowerCase())));

bool isOwnPlaylist(PlaylistsTableData p, String? me) =>
    canEditPlaylist(p, me) &&
    !(p.comment?.startsWith("Auto-imported from '") ?? false);

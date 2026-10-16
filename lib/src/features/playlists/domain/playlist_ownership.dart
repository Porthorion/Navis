import 'package:navis/src/database/navis_database.dart';

bool canEditPlaylist(PlaylistsTableData p, String? me) =>
    p.isLocal ||
    (p.readOnly != true &&
        (p.owner == null ||
            me == null ||
            p.owner!.toLowerCase() == me.toLowerCase()));

bool isOwnPlaylist(PlaylistsTableData p, String? me) =>
    canEditPlaylist(p, me) &&
    !(p.comment?.startsWith("Auto-imported from '") ?? false);

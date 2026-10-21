#!/usr/bin/env python3
"""Write deterministic Finder layout on the mounted installation image."""
import pathlib
import sys
from ds_store import DSStore
from mac_alias import Alias, Bookmark

root = pathlib.Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False,
        'WindowBounds': '{{180, 140}, {720, 460}}',
        'ContainerShowSidebar': False, 'PreviewPaneVisibility': False, 'SidebarWidth': 0,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        'backgroundImageAlias': Alias.for_file(str(root / '.background' / 'install.png')).to_bytes(),
        'iconSize': 96.0, 'textSize': 13.0, 'labelOnBottom': True,
        'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'showItemInfo': False, 'showIconPreview': False, 'arrangeBy': 'none',
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['pBBk'] = Bookmark.for_file(str(root / '.background' / 'install.png'))
    store['.']['icvl'] = ('type', b'icnv')
    store['.']['vstl'] = ('type', b'icnv')
    store['CodexUsageBar.app']['Iloc'] = (190, 220)
    store['Applications']['Iloc'] = (530, 220)

    # Keep helper entries outside the initial canvas even when Finder is configured
    # to show hidden files; do not change the user's global Finder preferences.
    for helper in ['.background', '.fseventsd', '.VolumeIcon.icns']:
        store[helper]['Iloc'] = (1800, 1400)

// Sample trees in the agent's `GET /v1/desktop/ui` response format for mobile view (11.4) tests. Generated from the
// agent helper's recorded trees (agent/test/py/fixtures: mousepad.json recorded on Xvfb, firefox.json hand-written)
// using the helper's own flattening (atspi_helper.walk); in mousepad the File menu is open and the text area filled.
import 'dart:convert';

/// Mousepad (GTK3): menu bar, open File menu, single-tab editor.
Map<String, dynamic> sampleUiMousepad() => jsonDecode(_mousepad) as Map<String, dynamic>;

/// Firefox 140: toolbar (back/forward, address field), two tabs, login page (heading, fields, password, checkbox,
/// toggle, button, slider, link).
Map<String, dynamic> sampleUiFirefox() => jsonDecode(_firefox) as Map<String, dynamic>;

const _mousepad = r'''
{
 "address": "0x55d1b2",
 "class": "org.xfce.mousepad",
 "gen": 1,
 "title": "Untitled 1 - Mousepad",
 "partial": false,
 "nodes": [
  {
   "id": "0.0.0",
   "parent": null,
   "depth": 0,
   "role": "menu bar",
   "name": "",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "0.0.0.0",
   "parent": "0.0.0",
   "depth": 1,
   "role": "menu",
   "name": "File",
   "desc": "",
   "states": [
    "enabled",
    "expanded",
    "selected"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.0",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "New",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.1",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "New Window",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.2",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu",
   "name": "New From Template",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.4",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Open...",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.5",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu",
   "name": "Open Recent",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.7",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Save",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.8",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Save As...",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.9",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Save All",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.10",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Reload",
   "desc": "",
   "states": [],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "0.0.0.0.12",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Print...",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.14",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Detach Tab",
   "desc": "",
   "states": [],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "0.0.0.0.16",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Close Tab",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.17",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Close Window",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.0.18",
   "parent": "0.0.0.0",
   "depth": 2,
   "role": "menu item",
   "name": "Quit",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.1",
   "parent": "0.0.0",
   "depth": 1,
   "role": "menu",
   "name": "Edit",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.2",
   "parent": "0.0.0",
   "depth": 1,
   "role": "menu",
   "name": "Search",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.3",
   "parent": "0.0.0",
   "depth": 1,
   "role": "menu",
   "name": "View",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.4",
   "parent": "0.0.0",
   "depth": 1,
   "role": "menu",
   "name": "Document",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.0.0.5",
   "parent": "0.0.0",
   "depth": 1,
   "role": "menu",
   "name": "Help",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "0.2.0",
   "parent": null,
   "depth": 0,
   "role": "page tab",
   "name": "",
   "desc": "",
   "states": [
    "enabled",
    "selected"
   ],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "0.2.0.0.0",
   "parent": "0.2.0",
   "depth": 1,
   "role": "text",
   "name": "",
   "desc": "",
   "states": [
    "enabled",
    "editable"
   ],
   "value": null,
   "text": "Alışveriş listesi:\n- süt\n- ekmek",
   "actions": []
  }
 ]
}
''';

const _firefox = r'''
{
 "address": "0x55d1a0",
 "class": "firefox-esr",
 "gen": 1,
 "title": "Giriş — Mozilla Firefox",
 "partial": false,
 "nodes": [
  {
   "id": "0",
   "parent": null,
   "depth": 0,
   "role": "tool bar",
   "name": "Gezinti",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "0.0",
   "parent": "0",
   "depth": 1,
   "role": "button",
   "name": "Geri",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "press"
   ]
  },
  {
   "id": "0.1",
   "parent": "0",
   "depth": 1,
   "role": "button",
   "name": "İleri",
   "desc": "",
   "states": [],
   "value": null,
   "text": null,
   "actions": [
    "press"
   ]
  },
  {
   "id": "0.2",
   "parent": "0",
   "depth": 1,
   "role": "combo box",
   "name": "Adres",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "0.2.0",
   "parent": "0.2",
   "depth": 2,
   "role": "entry",
   "name": "Ara ya da adres gir",
   "desc": "",
   "states": [
    "focused",
    "enabled",
    "editable"
   ],
   "value": null,
   "text": "https://example.com/giris",
   "actions": [
    "activate"
   ]
  },
  {
   "id": "1.0",
   "parent": null,
   "depth": 0,
   "role": "page tab",
   "name": "Giriş",
   "desc": "",
   "states": [
    "enabled",
    "selected"
   ],
   "value": null,
   "text": null,
   "actions": [
    "switch"
   ]
  },
  {
   "id": "1.1",
   "parent": null,
   "depth": 0,
   "role": "page tab",
   "name": "Haberler",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "switch"
   ]
  },
  {
   "id": "2.0",
   "parent": null,
   "depth": 0,
   "role": "document web",
   "name": "Giriş",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "2.0.0",
   "parent": "2.0",
   "depth": 1,
   "role": "heading",
   "name": "Hesabına gir",
   "desc": "",
   "states": [],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "2.0.1.0",
   "parent": "2.0",
   "depth": 1,
   "role": "label",
   "name": "Kullanıcı adı",
   "desc": "",
   "states": [],
   "value": null,
   "text": null,
   "actions": []
  },
  {
   "id": "2.0.1.1",
   "parent": "2.0",
   "depth": 1,
   "role": "entry",
   "name": "Kullanıcı adı",
   "desc": "",
   "states": [
    "enabled",
    "editable"
   ],
   "value": null,
   "text": "ayse",
   "actions": []
  },
  {
   "id": "2.0.1.2",
   "parent": "2.0",
   "depth": 1,
   "role": "password text",
   "name": "Şifre",
   "desc": "",
   "states": [
    "enabled",
    "editable"
   ],
   "value": null,
   "text": null,
   "password": true,
   "actions": []
  },
  {
   "id": "2.0.1.3",
   "parent": "2.0",
   "depth": 1,
   "role": "check box",
   "name": "Beni hatırla",
   "desc": "",
   "states": [
    "checked",
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "click"
   ]
  },
  {
   "id": "2.0.1.4",
   "parent": "2.0",
   "depth": 1,
   "role": "toggle button",
   "name": "Koyu tema",
   "desc": "",
   "states": [
    "checked",
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "press"
   ]
  },
  {
   "id": "2.0.1.5",
   "parent": "2.0",
   "depth": 1,
   "role": "button",
   "name": "Giriş yap",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "press"
   ]
  },
  {
   "id": "2.0.1.7",
   "parent": "2.0",
   "depth": 1,
   "role": "slider",
   "name": "Ses",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": {
    "now": 40,
    "min": 0,
    "max": 100,
    "step": 1
   },
   "text": null,
   "actions": []
  },
  {
   "id": "2.0.1.8",
   "parent": "2.0",
   "depth": 1,
   "role": "link",
   "name": "Şifremi unuttum",
   "desc": "",
   "states": [
    "enabled"
   ],
   "value": null,
   "text": null,
   "actions": [
    "jump"
   ]
  }
 ]
}
''';

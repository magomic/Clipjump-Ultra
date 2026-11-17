;@Plugin-Name Join lines
;@Plugin-Description Join lines to 1 commaseparated line
;@Plugin-Author ETU
;@Plugin-Tags pformat
;@Plugin-version 0.0.1
;@Plugin-Previewable 1
; Copyright 2026 Erhan Tuna - part of Clipjump-Ultra (https://github.com/magomic/Clipjump-Ultra), Apache License 2.0

;@Plugin-param1 Text to join

plugin_pformat_join(zin){
	tmp := RegExReplace(zin, "\R", ",")
	; remove a trailing comma (and optional spaces) from the joined string
	tmp := RegExReplace(tmp, ",\s*$", "")
	return tmp, STORE.ClipboardChanged := 1
}


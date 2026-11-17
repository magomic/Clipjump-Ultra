/*
	CJBase64 - paste an image clip as Base64 text (Ctrl+V + B in paste mode)

	Copyright 2026 Erhan Tuna - part of Clipjump-Ultra (https://github.com/magomic/Clipjump-Ultra)
	Licensed under the Apache License, Version 2.0 (see LICENSE and NOTICE.txt)

	The image is taken from the clipboard (paste mode has loaded the clip shown onto it):
	  1. a "PNG" clipboard format is used as it is (keeps transparency, no re-encoding)
	  2. otherwise the bitmap (CF_DIB / CF_BITMAP) is encoded as PNG with GDI+
	The PNG bytes are converted with CryptBinaryToStringW (one line, no line breaks) and pasted
	without becoming a clip; the previous clipboard is restored afterwards.
*/

; PNG bytes of the image on the clipboard into bin; returns the size (0 = no image)
CJBase64_ClipboardImage(ByRef bin){
	static fPng := DllCall("RegisterClipboardFormat", "Str", "PNG", "UInt")
	size := 0
	if (fPng && DllCall("IsClipboardFormatAvailable", "UInt", fPng) && DllCall("OpenClipboard", "Ptr", A_ScriptHwnd)) {
		if (h := DllCall("GetClipboardData", "UInt", fPng, "Ptr")) {
			n := DllCall("GlobalSize", "Ptr", h, "UPtr")
			if (n && (p := DllCall("GlobalLock", "Ptr", h, "Ptr"))) {
				VarSetCapacity(bin, n, 0)
				DllCall("RtlMoveMemory", "Ptr", &bin, "Ptr", p, "UPtr", n)
				DllCall("GlobalUnlock", "Ptr", h)
				size := CJBase64_PngLength(bin, n) 	; GlobalSize may be rounded up: cut after IEND
			}
		}
		DllCall("CloseClipboard")
		if size
			return size
	}
	pBitmap := Gdip_CreateBitmapFromClipboard()
	if (pBitmap = "" || pBitmap < 0 || pBitmap = 0)
		return 0
	tmp := A_Temp "\cj_base64_" A_TickCount ".png"
	Gdip_SaveBitmapToFile(pBitmap, tmp)
	Gdip_DisposeImage(pBitmap)
	f := FileOpen(tmp, "r")
	if IsObject(f) {
		size := f.Length
		VarSetCapacity(bin, size, 0)
		f.RawRead(bin, size) , f.Close()
	}
	FileDelete, %tmp%
	return size
}

; real length of PNG data (end of the IEND chunk); 0 if it is not PNG
CJBase64_PngLength(ByRef bin, n){
	if (n < 8 || NumGet(bin, 0, "UInt") != 0x474E5089) 	; \x89 P N G
		return 0
	off := 8
	while (off + 12 <= n) {
		len := (NumGet(bin, off, "UChar") << 24) | (NumGet(bin, off+1, "UChar") << 16)
			| (NumGet(bin, off+2, "UChar") << 8) | NumGet(bin, off+3, "UChar")
		next := off + 12 + len
		if (NumGet(bin, off+4, "UInt") = 0x444E4549) 	; "IEND"
			return next <= n ? next : 0
		off := next
	}
	return 0
}

; Base64 of bin (one line)
CJBase64_Encode(ByRef bin, size){
	static flags := 0x40000001 	; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
	if !DllCall("crypt32\CryptBinaryToStringW", "Ptr", &bin, "UInt", size, "UInt", flags, "Ptr", 0, "UInt*", n)
		return ""
	VarSetCapacity(out, n * 2, 0)
	if !DllCall("crypt32\CryptBinaryToStringW", "Ptr", &bin, "UInt", size, "UInt", flags, "Ptr", &out, "UInt*", n)
		return ""
	return StrGet(&out, n, "UTF-16")
}

CJBase64_EnsureIni(){
	Ini_write("Base64", "dataUri", 1)
}

; 1: B pastes a data URI (data:image/png;base64,...), 0: the bare Base64 text
CJBase64_DataUriOn(){
	return Trim(Ini_read("Base64", "dataUri")) = "0" ? 0 : 1
}

; pastes text without making it a clip, then restores the clipboard (also used by CJWrite)
cjPasteTextNoClip(ByRef text){
	API.blockMonitoring(1)
	try oldclip := ClipboardAll
	Clipboard := text
	API.blockMonitoring(0) , API.blockMonitoring(1)
	Send, ^{vk56}
	sleep % 150 + Min(StrLen(text) // 20000, 2850) 	; big texts: give the target time to read them
	try Clipboard := oldclip
	API.blockMonitoring(0)
}

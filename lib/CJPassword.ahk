/*
	CJPassword - recognize passwords copied from password managers, mask, encrypt and expire them

	Detection: password managers (KeePass, KeePassXC, 1Password, ...) put marker formats on the
	clipboard next to the text, asking clipboard monitors to ignore the content:
	  "ExcludeClipboardContentFromMonitorProcessing"  (Microsoft convention)
	  "Clipboard Viewer Ignore"                       (older convention)
	Checking them needs no OpenClipboard (IsClipboardFormatAvailable), so it never blocks the copy.

	A recognized clip is saved with the clip property "password" = 1 (prefs.ini of the channel, moves
	with the clip like "fixed" / "Tags"). It is not added to the clipboard history, and it cannot be
	exported or edited.

	Encryption (passwordClipEncryption=1): the clip file <n>.avc keeps its name (so every move / delete
	of clips works unchanged), but holds only the text, encrypted with Windows DPAPI (CryptProtectData,
	bound to the Windows user account):
	  "CJPW" (4 bytes) | UInt version = 1 | DPAPI blob of the UTF-16 text
	try_ClipboardfromFile() recognizes the header and puts the decrypted text on the clipboard together
	with the "do not record" markers, so the Windows clipboard history (Win+V) and cloud clipboard skip it.

	Lifetime (passwordLifetime=N minutes, 0 = never): a timer deletes password clips older than N minutes
	(age = file modification time: moves keep it, and password clips cannot be edited). The file is
	overwritten with zeros first. Skipped while paste mode or the Channel Organizer is open.

	Settings ([Privacy] in settings.ini, written with defaults by CJPassword_EnsureIni()):
	  maskPasswords          = 1   previews show only the first and last 2 characters (0: in full)
	  passwordClipEncryption = 1   store password clips encrypted (0: as normal clip file)
	  passwordLifetime       = 10  minutes until password clips are deleted (0: never)
*/

global CB_isPassword 	; set by onClipboardChange for the clip being saved right now

CJPassword_EnsureIni(){
	Ini_write("Privacy", "maskPasswords", 1)
	Ini_write("Privacy", "passwordClipEncryption", 1)
	Ini_write("Privacy", "passwordLifetime", 10)
	SetTimer, CJPassword_ExpireTick, 60000
}

; ---------------------------------------------------------------- settings
CJPassword_MaskOn(){
	return Trim(Ini_read("Privacy", "maskPasswords")) = "0" ? 0 : 1
}

CJPassword_EncryptOn(){
	return Trim(Ini_read("Privacy", "passwordClipEncryption")) = "0" ? 0 : 1
}

CJPassword_Lifetime(){ 	; minutes, 0 = never
	v := Trim(Ini_read("Privacy", "passwordLifetime"))
	if v is not number
		return 10
	return v > 0 ? v : 0
}

; ---------------------------------------------------------------- detection / clip property
; 1 if the current clipboard content carries a password manager marker
CJPassword_OnClipboard(){
	static f1 := DllCall("RegisterClipboardFormat", "Str", "ExcludeClipboardContentFromMonitorProcessing", "UInt")
	static f2 := DllCall("RegisterClipboardFormat", "Str", "Clipboard Viewer Ignore", "UInt")
	return (f1 && DllCall("IsClipboardFormatAvailable", "UInt", f1))
		|| (f2 && DllCall("IsClipboardFormatAvailable", "UInt", f2)) ? 1 : 0
}

; marks / unmarks the clip that was just saved (called before manageFIXATE, so it moves with the clip)
CJPassword_Tag(ch, cl, isPw){
	if isPw
		AddClipPref(ch, cl, "password", 1)
	else if IsObject(CPS[ch][cl]) && CPS[ch][cl].HasKey("password")
		CPS[ch][cl].Remove("password")
}

CJPassword_IsClip(ch, cl){
	return CPS[ch ? ch : 0][cl]["password"] ? 1 : 0
}

; password clip by property or by encrypted file (file = path of the .avc, optional)
CJPassword_IsPwClip(ch, cl, file := ""){
	if CJPassword_IsClip(ch, cl)
		return 1
	if (file = "")
		file := A_WorkingDir "\cache\clips" (ch ? ch : "") "\" cl ".avc"
	return CJPassword_IsEncFile(file)
}

; 1 if text is the text of a stored password clip (any channel; surrounding whitespace ignored).
; Used by read aloud / LLM as a central guard: covers paste mode, Clip Actions and selections alike.
CJPassword_IsPasswordText(text){
	t := Trim(text, " `t`r`n")
	if (t = "")
		return 0
	for ch, clips in CPS
		for cl, pr in clips
			if (IsObject(pr) && pr.password && Trim(CDS[ch][cl], " `t`r`n") == t)
				return 1
	return 0
}

; ---------------------------------------------------------------- display
; label for the preview: "Password" or "Password · 7 min left" (remaining passwordLifetime)
CJPassword_Label(ch, cl){
	r := CJPassword_Remaining(ch, cl)
	return TXT.TIP_pw_format (r != "" ? " " Chr(0xB7) " " r : "")
}

; remaining lifetime of a password clip as text ("" when passwordLifetime = 0 or no file)
; age = modification time of the clip file (written when copied; moves keep it)
CJPassword_Remaining(ch, cl){
	mins := CJPassword_Lifetime()
	if !mins
		return ""
	path := A_WorkingDir "\cache\clips" (ch ? ch : "") "\" cl ".avc"
	FileGetTime, t, %path%, M
	if (t = "")
		return ""
	age := A_Now
	EnvSub, age, %t%, Seconds
	left := Round(mins * 60) - age
	if (left <= 0)
		return TXT.TIP_pw_expiring 	; deleted on the next timer tick (within a minute)
	if (left < 60)
		return StrReplace(TXT.TIP_pw_left, "%t%", TXT.TIP_pw_lt1min)
	m := Ceil(left / 60) , h := m // 60 , m := Mod(m, 60)
	t := h ? StrReplace(StrReplace(TXT.TIP_pw_hm, "%h%", h), "%m%", m) : StrReplace(TXT.TIP_pw_m, "%m%", m)
	return StrReplace(TXT.TIP_pw_left, "%t%", t)
}

; text for display: masked when the clip is a password and masking is on
CJPassword_Display(ch, cl, text){
	if (text != "") && CJPassword_IsClip(ch, cl) && CJPassword_MaskOn()
		return CJPassword_Mask(text)
	return text
}

; "Geheim123" -> "Ge*****23"; 4 characters or less: all *
CJPassword_Mask(s){
	n := StrLen(s)
	if (n <= 4)
		return CJPassword_Stars(n)
	return SubStr(s, 1, 2) CJPassword_Stars(n - 4) SubStr(s, -1)
}

CJPassword_Stars(n){
	VarSetCapacity(s, n * 2)
	loop % n
		s .= "*"
	return s
}

; ---------------------------------------------------------------- encrypted clip files
CJPassword_IsEncFile(path){
	if !FileExist(path)
		return 0
	f := FileOpen(path, "r")
	if !IsObject(f)
		return 0
	ok := 0
	if (f.Length >= 8) {
		f.Seek(0, 0)
		ok := (f.ReadUInt() = 0x57504A43) 	; "CJPW"
	}
	f.Close()
	return ok
}

; writes the encrypted clip file (via <path>.new, so a half written file never replaces the old one)
CJPassword_SaveFile(path, text){
	size := CJPassword_Protect(text, blob)
	if !size
		return 0
	VarSetCapacity(hdr, 8, 0)
	NumPut(0x57504A43, hdr, 0, "UInt") , NumPut(1, hdr, 4, "UInt")
	f := FileOpen(path ".new", "w", "UTF-8-RAW")
	if !IsObject(f)
		return 0
	f.RawWrite(hdr, 8) , f.RawWrite(blob, size) , f.Close()
	FileMove, % path ".new", % path, 1
	return !ErrorLevel
}

; decrypted text of an encrypted clip file ("" if it cannot be decrypted)
CJPassword_LoadText(path){
	f := FileOpen(path, "r")
	if !IsObject(f)
		return ""
	n := f.Length - 8
	if (n <= 0) {
		f.Close()
		return ""
	}
	f.Seek(8, 0)
	VarSetCapacity(blob, n, 0)
	f.RawRead(blob, n) , f.Close()
	return CJPassword_Unprotect(blob, n)
}

; used by try_ClipboardfromFile(): decrypted text onto the clipboard, with the "do not record" markers
CJPassword_FileToClipboard(path){
	text := CJPassword_LoadText(path)
	if (text = "")
		return 0
	return CJPassword_SetClipboard(text)
}

CJPassword_SetClipboard(text){
	static fX := DllCall("RegisterClipboardFormat", "Str", "ExcludeClipboardContentFromMonitorProcessing", "UInt")
	static fH := DllCall("RegisterClipboardFormat", "Str", "CanIncludeInClipboardHistory", "UInt")
	static fC := DllCall("RegisterClipboardFormat", "Str", "CanUploadToCloudClipboard", "UInt")
	loop 100 {
		if (opened := DllCall("OpenClipboard", "Ptr", A_ScriptHwnd))
			break
		sleep 10
	}
	if !opened
		return 0
	DllCall("EmptyClipboard")
	bytes := (StrLen(text) + 1) * 2
	hText := DllCall("GlobalAlloc", "UInt", 0x42, "UPtr", bytes, "Ptr")
	p := DllCall("GlobalLock", "Ptr", hText, "Ptr")
	StrPut(text, p, "UTF-16")
	DllCall("GlobalUnlock", "Ptr", hText)
	ok := DllCall("SetClipboardData", "UInt", 13, "Ptr", hText, "Ptr") 	; CF_UNICODETEXT
	if !ok
		DllCall("GlobalFree", "Ptr", hText)
	for i, fmt in [fX, fH, fC] 	; DWORD 0: "no" for history / cloud, any data for the exclude marker
	{
		h := DllCall("GlobalAlloc", "UInt", 0x42, "UPtr", 4, "Ptr")
		if !DllCall("SetClipboardData", "UInt", fmt, "Ptr", h, "Ptr")
			DllCall("GlobalFree", "Ptr", h)
	}
	DllCall("CloseClipboard")
	return ok ? 1 : 0
}

; ---------------------------------------------------------------- DPAPI
CJPassword_Entropy(ByRef ent){
	static s := "Clipjump password clip v1"
	VarSetCapacity(ent, 2 * A_PtrSize, 0)
	NumPut(StrLen(s) * 2, ent, 0, "UInt") , NumPut(&s, ent, A_PtrSize, "Ptr")
}

CJPassword_Protect(text, ByRef out){
	n := StrLen(text) * 2
	VarSetCapacity(src, n + 2, 0) , StrPut(text, &src, "UTF-16")
	VarSetCapacity(inB, 2 * A_PtrSize, 0) , VarSetCapacity(outB, 2 * A_PtrSize, 0)
	NumPut(n, inB, 0, "UInt") , NumPut(&src, inB, A_PtrSize, "Ptr")
	CJPassword_Entropy(ent)
	ok := DllCall("crypt32\CryptProtectData", "Ptr", &inB, "Ptr", 0, "Ptr", &ent, "Ptr", 0, "Ptr", 0
		, "UInt", 1, "Ptr", &outB) 	; CRYPTPROTECT_UI_FORBIDDEN
	DllCall("RtlZeroMemory", "Ptr", &src, "UPtr", n + 2)
	if !ok
		return 0
	size := NumGet(outB, 0, "UInt") , p := NumGet(outB, A_PtrSize, "Ptr")
	VarSetCapacity(out, size, 0)
	DllCall("RtlMoveMemory", "Ptr", &out, "Ptr", p, "UPtr", size)
	DllCall("LocalFree", "Ptr", p)
	return size
}

CJPassword_Unprotect(ByRef blob, n){
	VarSetCapacity(inB, 2 * A_PtrSize, 0) , VarSetCapacity(outB, 2 * A_PtrSize, 0)
	NumPut(n, inB, 0, "UInt") , NumPut(&blob, inB, A_PtrSize, "Ptr")
	CJPassword_Entropy(ent)
	if !DllCall("crypt32\CryptUnprotectData", "Ptr", &inB, "Ptr", 0, "Ptr", &ent, "Ptr", 0, "Ptr", 0
		, "UInt", 1, "Ptr", &outB)
		return ""
	size := NumGet(outB, 0, "UInt") , p := NumGet(outB, A_PtrSize, "Ptr")
	text := StrGet(p, size // 2, "UTF-16")
	DllCall("RtlZeroMemory", "Ptr", p, "UPtr", size)
	DllCall("LocalFree", "Ptr", p)
	return text
}

; ---------------------------------------------------------------- lifetime
; deletes password clips older than passwordLifetime minutes; returns the number deleted
CJPassword_Expire(){
	global ctrlRef, is_pstMode_active, startUpComplete
	mins := CJPassword_Lifetime()
	if !mins || !startUpComplete
		return 0
	if (ctrlRef != "") || is_pstMode_active || WinExist(TXT.ORG__name " ahk_class AutoHotkeyGUI")
		return 0 	; clip numbers are in use there: try again on the next tick
	cutoff := A_Now
	EnvAdd, cutoff, -mins, Minutes
	deleted := 0
	loop % CN.Total
	{
		ch := A_Index - 1 , dir := A_WorkingDir "\cache\clips" (ch ? ch : "")
		list := ""
		loop, Files, %dir%\*.avc
		{
			n := SubStr(A_LoopFileName, 1, -4)
			if n is not integer
				continue
			if (A_LoopFileTimeModified > cutoff)
				continue
			if CJPassword_IsClip(ch, n) || (A_LoopFileSize < 16384 && CJPassword_IsEncFile(A_LoopFileFullPath))
				list .= n "`n"
		}
		if (list = "")
			continue
		Sort, list, N R 	; highest number first: deleting it does not renumber the lower ones
		loop, parse, list, `n
		{
			if (A_LoopField = "")
				continue
			CJPassword_Wipe(dir "\" A_LoopField ".avc")
			if API.deleteClip(ch, API.getChStrength(ch) - A_LoopField + 1)
				deleted++
		}
	}
	if deleted
		Prefs2Ini()
	return deleted
}

; overwrites a file with zeros (before it is deleted)
CJPassword_Wipe(path){
	f := FileOpen(path, "rw")
	if !IsObject(f)
		return
	n := f.Length
	if (n > 0) {
		VarSetCapacity(z, n, 0)
		f.Seek(0, 0) , f.RawWrite(z, n)
	}
	f.Close()
}

CJPassword_ExpireTick:
	CJPassword_Expire()
	return

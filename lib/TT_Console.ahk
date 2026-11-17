; Modified for Clipjump-Ultra by Erhan Tuna, 2026 - see NOTICE.txt (Apache License 2.0)
/*
TT_Console() v0.03
	Use Tooltip as a User Interface

By:
	Avi Aryan

Info:
	keys - stores space separated values of keys that are prompted for a user input
	font_options - Font options as in Gui ( eg -> s8 bold underline )
	font_face - Font face names. Separate them by a | to set prority

Returns >
	The key which has been pressed
*/

;EXAMPLE
;a := TT_Console( "Hi`nPress Y to see another message.`nPress N to exit script", "y n", empty_var, empty_var, 1, "s12", "Arial|Consolas")
;if a = y
;...
;return


TT_Console(msg, keys, x:="", y:="", fontops:="", fontname:="", whichtooltip:=1, followMouse:=0, TabStops:="") {

	; whichtooltip = "panel": the caller draws its own UI (modern panel), only wait for the key here
	;   followMouse can then be a function object, called while waiting (e.g. to move the panel)
	noDraw := (whichtooltip = "panel")
	RegExMatch(fontops, "\d+", FontSize)
	; btt 可以直接处理字体，所以这里不用 gethfont 处理了。
	if !noDraw
		btt(msg, x, y, whichtooltip, {Font:fontname, FontSize:FontSize, TabStops:[TabStops]})

	;create hotkeys
	loop, parse, keys, %A_space%, %a_space%
		hkZ(A_LoopField, "TT_Console_Check", 1)

	is_TTkey_pressed := 0
	while !is_TTkey_pressed
	{
		if followMouse && !noDraw
		{
			btt(msg,,, whichtooltip)
			sleep 100
		} else {
			if (noDraw && IsObject(followMouse))
				followMouse.Call()
			sleep 20
		}
	}

	if !noDraw
		btt(,,, whichtooltip)

	loop, parse, keys, %A_space%, %a_space%
		hkZ(A_LoopField, "TT_Console_Check", 0)

	return what_pressed


TT_Console_Check:
	what_pressed := A_ThisHotkey
	is_TTkey_pressed := 1
	return
}


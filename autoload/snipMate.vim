fun! Filename(...)
	let filename = expand('%:t:r')
	if filename == '' | return a:0 == 2 ? a:2 : '' | endif
	return !a:0 || a:1 == '' ? filename : substitute(a:1, '$1', filename, 'g')
endf

fun! s:RemoveSnippet()
	unl! g:snipPos s:curPos s:snipLen s:endCol s:endLine s:prevLen
	     \ s:lastBuf s:oldWord
	if exists('s:update')
		unl s:startCol s:origWordLen s:update
		if exists('s:oldVars') | unl s:oldVars s:oldEndCol | endif
	endif
	aug! snipMateAutocmds
endf

fun! s:Indent(line)
	return matchend(a:line, '^.\{-}\ze\(\S\|$\)') + 1
endf
fun! s:CorrectWrongIndent(indentStr)
	let l:indentStr = a:indentStr

	" Spaces before Tabs may not contribute to indent, so remove them.
	let i = 1
	while indentStr =~# '\%>' . (i * 8) . 'v.'
		let indentStr = substitute(indentStr, printf("\\%%%dv \\{1,%d}\\t", i * 8 + 1, &ts - 1), "\t", 'g')
		let i += 1
	endwhile
	return indentStr
endf
fun! s:ReIndent(lnum)
	let line = getline(a:lnum)
	let nonIndentCol = s:Indent(line) - 1
	let indentStr = strpart(line, 0, nonIndentCol)
	let nonIndentStr = strpart(line, nonIndentCol)
	let indentStr = s:CorrectWrongIndent(indentStr)
	let indent = strlen(substitute(indentStr, "\t", repeat(' ', &ts), 'g'))

	let stsIndentStr = repeat("\t", indent / &ts) . repeat(' ', indent % &ts)
	call setline(a:lnum, stsIndentStr . nonIndentStr)
	return strlen(stsIndentStr)
endf
let s:unescaped =  '\%(\%(^\|[^\\]\)\%(\\\\\)*\\\)\@<!'
let s:unescapedDollar =  s:unescaped . '$'
fun! snipMate#expandSnip(snip, col)
	let lnum = line('.') | let col = a:col

	let snippet = s:ProcessSnippet(a:snip)
	" Avoid error if eval evaluates to nothing
	if snippet == '' | return '' | endif

	" Expand snippet onto current position with the tab stops removed and
	" escapings removed
	let processedSnippet = substitute(snippet, s:unescapedDollar.'\%(\d\+\|{\d\+.\{-}'.s:unescaped.'}\)', '', 'g')
	let processedSnippet = s:Unescape(processedSnippet, '[$\\]')
	let snipLines = split(processedSnippet, "\n", 1)

	let endlnum = lnum + len(snipLines) - 1
	let line = getline(lnum)
	let afterCursor = strpart(line, col - 1)
	" Keep text after the cursor
	if afterCursor != "\t" && afterCursor != ' '
		let line = strpart(line, 0, col - 1)
		let snipLines[-1] .= afterCursor
	else
		let afterCursor = ''
		" For some reason the cursor needs to move one right after this
		if line != '' && col == 1 && &ve != 'all' && &ve != 'onemore'
			let col += 1
		endif
	endif

	call setline(lnum, line.snipLines[0])

	" Autoindent snippet according to previous indentation
	let indent = s:Indent(line)
	call append(lnum, map(snipLines[1:], "'".strpart(line, 0, indent - 1)."'.v:val"))

	" Correct the indent to tabs followed by optional spaces if 'softtabstop'
	" This merges the existing indent with the snippet's indent (which was
	" preliminarily converted to spaces), and ensures that the result again is a
	" proper 'softtabstop' indent of tabs followed by optional spaces.
	if &sts && ! &et
		let l:cursorCol = col('.')

		let lineIndentCols = map(range(lnum, endlnum), 's:ReIndent(v:val)')
		let snipIndentCols = map(copy(snipLines), 's:Indent(v:val) - 1')
		" The re-indenting may have changed the number of bytes allocated for
		" the indent, and this change may be different for every snippet line.
		let indents = []
		for i in range(len(snipLines))
			call add(indents, lineIndentCols[i] - snipIndentCols[i] + 1)
		endfor

		" Adapt if the amount of indent was changed by the merging of the
		" existing indent with the snippet's indent (or by superfluous spaces in
		" the existing indent).
		let lineIndentDelta = indents[0] - indent
		if lineIndentDelta != 0
			call cursor(line('.'), l:cursorCol + lineIndentDelta)
			let col += lineIndentDelta
		endif
	else
		let indents = repeat([indent], len(snipLines))
	endif

	" Open any folds snippet expands into
	if &fen | sil! exe lnum.','.endlnum.'foldopen' | endif

	" For correct accounting, unescape the snippet and avoid that the
	" formerly escaped dollar signs are interpreted as placeholders /
	" mirrors. This is done by simply replacing them with a "harmless"
	" character.
	let [g:snipPos, s:snipLen] = s:BuildTabStops(s:Defuse(snippet, '[$\\]'), lnum, col, indents)

	if s:snipLen
		aug snipMateAutocmds
			au CursorMovedI * call s:UpdateChangedSnip(0)
			au InsertEnter * call s:UpdateChangedSnip(1)
		aug END
		let s:lastBuf = bufnr(0) " Only expand snippet while in current buffer
		let s:curPos = 0
		let s:endCol = g:snipPos[s:curPos][1]
		let s:endLine = g:snipPos[s:curPos][0]

		call cursor(g:snipPos[s:curPos][0], g:snipPos[s:curPos][1])
		let s:prevLen = [line('$'), col('$')]
		if g:snipPos[s:curPos][2] != -1 | return s:SelectWord() | endif
	else
		unl g:snipPos s:snipLen
		" Place cursor at end of snippet if no tab stop is given
		let newlines = len(snipLines) - 1
		let endCol = len(snipLines[-1]) - len(afterCursor)
					 \ + (newlines ? indent : col)
		call cursor(lnum + newlines, endCol)
	endif
	return ''
endf

" Prepare snippet to be processed by s:BuildTabStops
fun! s:Unescape(text, what)
	return substitute(a:text, s:unescaped.'\\\ze' . a:what, '', 'g')
endf
fun! s:Defuse(text, what)
	return substitute(a:text, s:unescaped.'\\' . a:what, '?', 'g')
endf
fun! s:ProcessSnippet(snip)
	let snippet = a:snip

	" Evaluate eval (`...`) expressions, unless escaped (\`).
	let parts = split(snippet, s:unescaped.'`', 1)
	let snippet = s:Unescape(parts[0], '`')
	let partIdx = 1
	while partIdx < len(parts)
		let snippet .= substitute(eval(s:Unescape(parts[partIdx], '[`\\]')), "\n$", '', '')
		let snippet .= s:Unescape(get(parts, partIdx + 1), '`')
		let partIdx += 2
	endwhile

	let snippet = substitute(snippet, "\r", "\n", 'g')

	" Place all text after a colon in a tab stop after the tab stop
	" (e.g. "${#:foo}" becomes "${:foo}foo").
	" This helps tell the position of the tab stops later.
	let snippet = substitute(snippet, s:unescapedDollar.'{\d\+:\(.\{-}'.s:unescaped.'\)}', '\=submatch(0) . s:Unescape(submatch(1), "}")', 'g')

	" Update the a:snip so that all the $# become the text after
	" the colon in their associated ${#}.
	" (e.g. "${1:foo}" turns all "$1"'s into "foo")
	let i = 1
	while stridx(snippet, '${'.i) != -1
		let s = matchstr(snippet, s:unescapedDollar.'{'.i.':\zs.\{-}'.s:unescaped.'\ze}')
		if s != ''
			let snippet = substitute(snippet, s:unescapedDollar.i, s.'&', 'g')
		endif
		let i += 1
	endw

	if &et " Expand tabs to spaces if 'expandtab' is set.
		return substitute(snippet, '\t', repeat(' ', &sts ? &sts : &ts), 'g')
	elseif &sts " Preliminarily render indent as spaces if 'softtabstop' is set.
		return substitute(snippet, '\%(^\|\n\zs\)\t\+', '\=repeat(" ", &sts * strlen(submatch(0)))', 'g')
	endif
	return snippet
endf

" Counts occurences of haystack in needle
fun! s:Count(haystack, needle)
	let counter = 0
	let index = stridx(a:haystack, a:needle)
	while index != -1
		let index = stridx(a:haystack, a:needle, index+1)
		let counter += 1
	endw
	return counter
endf

" Builds a list of a list of each tab stop in the snippet containing:
" 1.) The tab stop's line number.
" 2.) The tab stop's column number
"     (by getting the length of the string between the last "\n" and the
"     tab stop).
" 3.) The length of the text after the colon for the current tab stop
"     (e.g. "${1:foo}" would return 3). If there is no text, -1 is returned.
" 4.) If the "${#:}" construct is given, another list containing all
"     the matches of "$#", to be replaced with the placeholder. This list is
"     composed the same way as the parent; the first item is the line number,
"     and the second is the column.
fun! s:BuildTabStops(snip, lnum, col, indents)
	let snipPos = []
	let i = 1
	let withoutVars = substitute(a:snip, '$\d\+', '', 'g')
	while stridx(a:snip, '${'.i) != -1
		let beforeTabStop = matchstr(withoutVars, '^.*\ze${'.i.'\D')
		let withoutOthers = substitute(withoutVars, '${\('.i.'\D\)\@!\d\+.\{-}'.s:unescaped.'}', '', 'g')

		let j = i - 1
		call add(snipPos, [0, 0, -1])
		let tabStopLnum = s:Count(beforeTabStop, "\n")
		let snipPos[j][0] = a:lnum + tabStopLnum
		let snipPos[j][1] = a:indents[tabStopLnum] + len(matchstr(withoutOthers, '.*\(\n\|^\)\zs.*\ze${'.i.'\D'))
		if snipPos[j][0] == a:lnum | let snipPos[j][1] += a:col - a:indents[0] | endif

		" Get all $# matches in another list, if ${#:name} is given
		if stridx(withoutVars, '${'.i.':') != -1
			let snipPos[j][2] = len(s:Unescape(matchstr(withoutVars, '${'.i.':\zs.\{-}\ze'.s:unescaped.'}'), '[}\\]'))
			let dots = repeat('.', snipPos[j][2])
			call add(snipPos[j], [])
			let withoutOthers = substitute(a:snip, '${\d\+.\{-}'.s:unescaped.'}\|$'.i.'\@!\d\+', '', 'g')
			while match(withoutOthers, '$'.i.'\(\D\|$\)') != -1
				let beforeMark = matchstr(withoutOthers, '^.\{-}\ze'.dots.'$'.i.'\(\D\|$\)')
				call add(snipPos[j][3], [0, 0])
				let markLnum = s:Count(beforeMark, "\n")
				let snipPos[j][3][-1][0] = a:lnum + markLnum
				let snipPos[j][3][-1][1] = a:indents[markLnum] + (snipPos[j][3][-1][0] > a:lnum
				                           \ ? len(matchstr(beforeMark, '.*\n\zs.*'))
				                           \ : a:col - a:indents[markLnum] + len(beforeMark))
				let withoutOthers = substitute(withoutOthers, '$'.i.'\ze\(\D\|$\)', '', '')
			endw
		endif
		let i += 1
	endw
	return [snipPos, i - 1]
endf

fun! snipMate#jumpTabStop(backwards)
	let leftPlaceholder = exists('s:origWordLen')
	                      \ && s:origWordLen != g:snipPos[s:curPos][2]
	if leftPlaceholder && exists('s:oldEndCol')
		let startPlaceholder = s:oldEndCol + 1
	endif

	if exists('s:update')
		call s:UpdatePlaceholderTabStops()
	else
		call s:UpdateTabStops()
	endif

	" Don't reselect placeholder if it has been modified
	if leftPlaceholder && g:snipPos[s:curPos][2] != -1
		if ! exists('startPlaceholder')
			let g:snipPos[s:curPos][1] = col('.')
			let g:snipPos[s:curPos][2] = 0
		endif
	endif

	let s:curPos += a:backwards ? -1 : 1
	" Loop over the snippet when going backwards from the beginning
	if s:curPos < 0 | let s:curPos = s:snipLen - 1 | endif

	if s:curPos == s:snipLen
		let sMode = s:endCol == g:snipPos[s:curPos-1][1]+g:snipPos[s:curPos-1][2]
		call s:RemoveSnippet()
		return sMode ? g:snipMate_triggerKey : TriggerSnippet()
	endif

	call cursor(g:snipPos[s:curPos][0], g:snipPos[s:curPos][1])

	let s:endLine = g:snipPos[s:curPos][0]
	let s:endCol = g:snipPos[s:curPos][1]
	let s:prevLen = [line('$'), col('$')]

	return g:snipPos[s:curPos][2] == -1 ? '' : s:SelectWord()
endf

fun! s:UpdatePlaceholderTabStops()
	let changeLen = s:origWordLen - g:snipPos[s:curPos][2]
	unl s:startCol s:origWordLen s:update
	if !exists('s:oldVars') | return | endif
	" Update tab stops in snippet if text has been added via "$#"
	" (e.g., in "${1:foo}bar$1${2}").
	if changeLen != 0
		let curLine = line('.')

		for pos in g:snipPos
			let isCurrent = (pos == g:snipPos[s:curPos])
			let changed = pos[0] == curLine && pos[1] > s:oldEndCol
			let changedVars = 0
			let endPlaceholder = pos[2] - 1 + pos[1]
			" Subtract changeLen from each tab stop that was after any of
			" the current tab stop's placeholders.
			for [lnum, col] in s:oldVars
				if lnum > pos[0] | break | endif
				if pos[0] == lnum
					if pos[1] > col || (pos[2] == -1 && pos[1] == col)
						let changed += 1
					elseif col < endPlaceholder
						let changedVars += 1
					endif
				endif
			endfor
			if isCurrent
				" Must process the current entry, but with a reduced
				" count?!
				let l:changed -= 1
			endif
			let pos[1] -= changeLen * changed
			let pos[2] -= changeLen * changedVars " Parse variables within placeholders
                                                  " e.g., "${1:foo} ${2:$1bar}"

			if isCurrent | continue | endif
			if pos[2] == -1 | continue | endif
			" Do the same to any placeholders in the other tab stops.
			for nPos in pos[3]
				let changed = nPos[0] == curLine && nPos[1] > s:oldEndCol
				for [lnum, col] in s:oldVars
					if lnum > nPos[0] | break | endif
					if nPos[0] == lnum && nPos[1] > col
						let changed += 1
					endif
				endfor
				let nPos[1] -= changeLen * changed
			endfor
		endfor
	endif
	unl s:endCol s:oldVars s:oldEndCol
endf

fun! s:UpdateTabStops()
	let changeLine = s:endLine - g:snipPos[s:curPos][0]
	let changeCol = s:endCol - g:snipPos[s:curPos][1]
	if exists('s:origWordLen')
		let changeCol -= s:origWordLen
		unl s:origWordLen
	endif
	let lnum = g:snipPos[s:curPos][0]
	let col = g:snipPos[s:curPos][1]
	" Update the line number of all proceeding tab stops if <cr> has
	" been inserted.
	if changeLine != 0
		let changeLine -= 1
		for pos in g:snipPos
			if pos[0] >= lnum
				if pos[0] == lnum | let pos[1] += changeCol | endif
				let pos[0] += changeLine
			endif
			if pos[2] == -1 | continue | endif
			for nPos in pos[3]
				if nPos[0] >= lnum
					if nPos[0] == lnum | let nPos[1] += changeCol | endif
					let nPos[0] += changeLine
				endif
			endfor
		endfor
	elseif changeCol != 0
		" Update the column of all proceeding tab stops if text has
		" been inserted/deleted in the current line.
		for pos in g:snipPos
			if pos[1] >= col && pos[0] == lnum
				let pos[1] += changeCol
			endif
			if pos[2] == -1 | continue | endif
			for nPos in pos[3]
				if nPos[0] > lnum | break | endif
				if nPos[0] == lnum && nPos[1] >= col
					let nPos[1] += changeCol
				endif
			endfor
		endfor
	endif
endf

fun! s:SelectWord()
	let s:origWordLen = g:snipPos[s:curPos][2]
	let s:oldWord = strpart(getline('.'), g:snipPos[s:curPos][1] - 1,
				\ s:origWordLen)
	let s:prevLen[1] -= s:origWordLen
	if !empty(g:snipPos[s:curPos][3])
		let s:update = 1
		let s:endCol = -1
		let s:startCol = g:snipPos[s:curPos][1] - 1
	endif
	if !s:origWordLen | return '' | endif
	let l = col('.') != 1 ? 'l' : ''
	if &sel == 'exclusive'
		return "\<esc>".l.'v'.s:origWordLen."l\<c-g>"
	endif
	return s:origWordLen == 1 ? "\<esc>".l.'gh'
							\ : "\<esc>".l.'v'.(s:origWordLen - 1)."l\<c-g>"
endf

" This updates the snippet as you type when text needs to be inserted
" into multiple places (e.g. in "${1:default text}foo$1bar$1",
" "default text" would be highlighted, and if the user types something,
" UpdateChangedSnip() would be called so that the text after "foo" & "bar"
" are updated accordingly)
"
" It also automatically quits the snippet if the cursor is moved out of it
" while in insert mode.
fun! s:UpdateChangedSnip(entering)
	if exists('g:snipPos') && bufnr(0) != s:lastBuf
		call s:RemoveSnippet()
	elseif exists('s:update') " If modifying a placeholder
		if !exists('s:oldVars') && s:curPos + 1 < s:snipLen
			" Save the old snippet & word length before it's updated
			" s:startCol must be saved too, in case text is added
			" before the snippet (e.g. in "foo$1${2}bar${1:foo}").
			let s:oldEndCol = s:startCol
			let s:oldVars = deepcopy(g:snipPos[s:curPos][3])
		endif
		let col = col('.') - 1

		if s:endCol != -1
			let changeLen = col('$') - s:prevLen[1]
			let s:endCol += changeLen
		else " When being updated the first time, after leaving select mode
			if a:entering | return | endif
			let s:endCol = col - 1
		endif

		" If the cursor moves outside the snippet, quit it
		if line('.') != g:snipPos[s:curPos][0] || col < s:startCol ||
					\ col - 1 > s:endCol
			unl! s:startCol s:origWordLen s:oldVars s:update
			return s:RemoveSnippet()
		endif

		call s:UpdateVars()
		let s:prevLen[1] = col('$')
	elseif exists('g:snipPos')
		if !a:entering && g:snipPos[s:curPos][2] != -1
			let g:snipPos[s:curPos][2] = -2
		endif

		let col = col('.')
		let lnum = line('.')
		let changeLine = line('$') - s:prevLen[0]

		if lnum == s:endLine
			let s:endCol += col('$') - s:prevLen[1]
			let s:prevLen = [line('$'), col('$')]
		endif
		if changeLine != 0
			let s:endLine += changeLine
			let s:endCol = col
		endif

		" Delete snippet if cursor moves out of it in insert mode
		if (lnum == s:endLine && (col > s:endCol || col < g:snipPos[s:curPos][1]))
			\ || lnum > s:endLine || lnum < g:snipPos[s:curPos][0]
			call s:RemoveSnippet()
		endif
	endif
endf

" This updates the variables in a snippet when a placeholder has been edited.
" (e.g., each "$1" in "${1:foo} $1bar $1bar")
fun! s:UpdateVars()
	let newWordLen = s:endCol - s:startCol + 1
	let newWord = strpart(getline('.'), s:startCol, newWordLen)
	if newWord == s:oldWord || empty(g:snipPos[s:curPos][3])
		return
	endif

	let changeLen = g:snipPos[s:curPos][2] - newWordLen
	let curLine = line('.')
	let startCol = col('.')
	let oldStartSnip = s:startCol
	let updateTabStops = changeLen != 0
	let i = 0

	for [lnum, col] in g:snipPos[s:curPos][3]
		if updateTabStops
			let start = s:startCol
			if lnum == curLine && col <= start
				let s:startCol -= changeLen
				let s:endCol -= changeLen
			endif
			for nPos in g:snipPos[s:curPos][3][(i):]
				" This list is in ascending order, so quit if we've gone too far.
				if nPos[0] > lnum | break | endif
				if nPos[0] == lnum && nPos[1] > col
					let nPos[1] -= changeLen
				endif
			endfor
			if lnum == curLine && col > start
				let col -= changeLen
				let g:snipPos[s:curPos][3][i][1] = col
			endif
			let i += 1
		endif
		if col > 0 " XXX: To avoid script error.
			" "Very nomagic" is used here to allow special characters.
			call setline(lnum, substitute(getline(lnum), '\%'.col.'c\V'.
							\ escape(s:oldWord, '\'), escape(newWord, '\&'), ''))
		endif
	endfor
	if oldStartSnip != s:startCol
		call cursor(0, startCol + s:startCol - oldStartSnip)
	endif

	let s:oldWord = newWord
	let g:snipPos[s:curPos][2] = newWordLen
endf
" vim:noet:sw=4:ts=4:ft=vim

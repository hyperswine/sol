# web.sol — LEGACY: the untyped record view vocabulary. Superseded by
# lib/ui.sol (typed Html ADT + Style symbols); kept only so old pinned
# imports keep resolving. New code should use ui.sol.

node tag cls kids = {cls = cls, kids = kids, tag = tag}.
text s = {text = s}.
dynS name n = {dyn = name, node = n}.
clickable ev val n = {ev = ev, node = n, val = val}.
inputBox name ph btn = {btn = btn, inp = name, ph = ph}.
formBox ev fields btn = {btn = btn, fields = fields, form = ev}.

# conveniences
row cls kids = node "div" "flex flex-row gap-2 {cls}" kids.
col cls kids = node "div" "flex flex-col gap-2 {cls}" kids.
card kids = node "div" "card flex flex-col gap-2" kids.
badge s = node "span" "badge" [text s].
tabBtn ev val label = clickable ev val (node "span" "tab" [text label]).
btn ev val label = clickable ev val (node "span" "btn" [text label]).
title s = node "h1" "text-2xl font-bold" [text s].
subtitle s = node "h3" "font-bold" [text s].
muted s = node "span" "text-muted" [text s].

#!/usr/bin/env zsh
# json2dir: create the directory tree a JSON document describes, in the current directory.
# Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
# Pure zsh: no external commands, only builtins and the zsh/system, zsh/files and zsh/stat modules.

emulate -R zsh
setopt no_multibyte no_clobber   # byte-level strings; '>' never overwrites (O_EXCL)
path=()                          # no external programs, ever

zmodload zsh/system zsh/files || exit 1
zmodload -F zsh/stat b:zstat || exit 1

die() {
  print -ru2 -- "json2dir: $1"
  exit 1
}

# ---------------------------------------------------------------- parser
# The document is flattened into parallel arrays, in document (pre-)order:
#   KIND[i]  d (directory) | f (file) | x (script) | l (link)
#   PATHS[i] path relative to the target directory, names joined with "/"
#   DATA[i]  file content or link target
typeset -a KIND PATHS DATA
# raw holds the whole input; p is the 1-based byte position in it. In zsh 5.8, indexing a long
# string or array costs time proportional to the index, so bytes are read from buf, a window of
# raw split into one byte per element, starting after byte base. fill moves the window to p;
# the loops that advance p call it when fewer than 16 bytes of lookahead remain.
typeset raw
typeset -a buf
integer p n base
integer -r W=4096

fill() {
  base=p-1
  buf=( "${(@s::)raw[p,p+W-1]}" )
}

skip_ws() {
  while (( p <= n )); do
    (( p - base > W - 16 )) && fill
    case ${buf[p-base]} in
      ($' '|$'\t'|$'\n'|$'\r') (( p++ )) ;;
      (*) return ;;
    esac
  done
}

expect() {   # expect <char> <what>
  skip_ws
  [[ ${buf[p-base]} == "$1" ]] || die "invalid JSON at byte $p: expected $2"
  (( p++ ))
}

hex4() {     # reads 4 hex digits at p into REPLY (as a number)
  local h=${(j::)buf[p-base,p-base+3]}
  [[ $h == [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F] ]] || die "invalid JSON at byte $p: bad \\u escape"
  (( p += 4 ))
  REPLY=$(( 16#$h ))
}

utf8() {     # encodes code point $1 as UTF-8 bytes into REPLY
  integer cp=$1
  if (( cp < 0x80 )); then
    REPLY=${(#)cp}
  elif (( cp < 0x800 )); then
    REPLY=${(#)$(( 0xC0 | cp >> 6 ))}${(#)$(( 0x80 | cp & 0x3F ))}
  elif (( cp < 0x10000 )); then
    REPLY=${(#)$(( 0xE0 | cp >> 12 ))}${(#)$(( 0x80 | (cp >> 6) & 0x3F ))}${(#)$(( 0x80 | cp & 0x3F ))}
  else
    REPLY=${(#)$(( 0xF0 | cp >> 18 ))}${(#)$(( 0x80 | (cp >> 12) & 0x3F ))}${(#)$(( 0x80 | (cp >> 6) & 0x3F ))}${(#)$(( 0x80 | cp & 0x3F ))}
  fi
}

# Parses a JSON string at p (which must be at the opening quote) into REPLY, as UTF-8 bytes.
# Validates UTF-8 strictly and rejects unpaired surrogate escapes.
parse_string() {
  skip_ws
  [[ ${buf[p-base]} == '"' ]] || die "invalid JSON at byte $p: expected a string"
  (( p++ ))
  local out= c d
  integer start=p
  integer b need lo hi i cp cp2
  while true; do
    (( p > n )) && die "invalid JSON: unterminated string"
    if (( p - base > W - 16 )); then   # flush the pending run before moving the window
      out+=${(j::)buf[start-base,p-1-base]}
      start=p
      fill
    fi
    c=${buf[p-base]}
    if [[ $c == [\ -~] && $c != [\"\\] ]]; then   # fast path: printable ASCII
      (( p++ ))
      continue
    fi
    b=$(( #c ))
    if [[ $c == '"' ]]; then
      out+=${(j::)buf[start-base,p-1-base]}
      (( p++ ))
      break
    elif [[ $c == '\' ]]; then
      out+=${(j::)buf[start-base,p-1-base]}
      d=${buf[p-base+1]}
      (( p += 2 ))
      case $d in
        ('"') out+='"' ;;
        ('\') out+='\' ;;
        ('/') out+='/' ;;
        (b) out+=$'\b' ;;
        (f) out+=$'\f' ;;
        (n) out+=$'\n' ;;
        (r) out+=$'\r' ;;
        (t) out+=$'\t' ;;
        (u)
          hex4; cp=$REPLY
          if (( cp >= 0xD800 && cp <= 0xDBFF )); then
            [[ ${(j::)buf[p-base,p-base+1]} == '\u' ]] || die "string contains an unpaired surrogate"
            (( p += 2 ))
            hex4; cp2=$REPLY
            (( cp2 >= 0xDC00 && cp2 <= 0xDFFF )) || die "string contains an unpaired surrogate"
            cp=$(( 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00) ))
          elif (( cp >= 0xDC00 && cp <= 0xDFFF )); then
            die "string contains an unpaired surrogate"
          fi
          utf8 $cp
          out+=$REPLY
          ;;
        (*) die "invalid JSON at byte $(( p - 1 )): bad escape" ;;
      esac
      start=p
    elif (( b < 0x20 )); then
      die "invalid JSON at byte $p: control character in string"
    elif (( b < 0x80 )); then
      (( p++ ))
    else
      # strict UTF-8: lead byte, then continuation bytes with the first one range-limited
      lo=0x80 hi=0xBF
      if (( b >= 0xC2 && b <= 0xDF )); then need=1
      elif (( b == 0xE0 )); then need=2 lo=0xA0
      elif (( b == 0xED )); then need=2 hi=0x9F
      elif (( b >= 0xE1 && b <= 0xEF )); then need=2
      elif (( b == 0xF0 )); then need=3 lo=0x90
      elif (( b == 0xF4 )); then need=3 hi=0x8F
      elif (( b >= 0xF1 && b <= 0xF3 )); then need=3
      else die "input is not valid UTF-8 (byte $p)"
      fi
      for (( i = 1; i <= need; i++ )); do
        (( p + i <= n )) || die "input is not valid UTF-8 (byte $p)"
        d=${buf[p-base+i]}
        b=$(( #d ))
        (( b >= lo && b <= hi )) || die "input is not valid UTF-8 (byte $(( p + i )))"
        lo=0x80 hi=0xBF
      done
      (( p += need + 1 ))
    fi
  done
  REPLY=$out
}

# A member value: object, string, or ["link"|"script", string]. Anything else is rejected.
parse_value() {   # parse_value <path>
  local where=$1
  skip_ws
  case ${buf[p-base]} in
    ('{') parse_object "$where" ;;
    ('"')
      parse_string
      KIND+=(f) PATHS+=("$where") DATA+=("$REPLY")
      ;;
    ('[')
      (( p++ ))
      skip_ws
      [[ ${buf[p-base]} == '"' ]] || die "$where: an array must be [\"link\", target] or [\"script\", content]"
      parse_string; local kind=$REPLY
      skip_ws
      [[ ${buf[p-base]} == ',' ]] || die "$where: an array must be [\"link\", target] or [\"script\", content]"
      (( p++ ))
      skip_ws
      [[ ${buf[p-base]} == '"' ]] || die "$where: an array must be [\"link\", target] or [\"script\", content]"
      parse_string; local payload=$REPLY
      skip_ws
      [[ ${buf[p-base]} == ']' ]] || die "$where: an array must be [\"link\", target] or [\"script\", content]"
      (( p++ ))
      case $kind in
        (link)
          [[ $payload == *$'\0'* ]] && die "$where: a link target cannot contain NUL"
          KIND+=(l) ;;
        (script) KIND+=(x) ;;
        (*) die "$where: unknown array kind \"$kind\"" ;;
      esac
      PATHS+=("$where") DATA+=("$payload")
      ;;
    ('') die "invalid JSON: unexpected end of input" ;;
    (*) die "$where: only objects, strings and arrays are allowed (byte $p)" ;;
  esac
}

parse_object() {  # parse_object <path>; root is "."
  local where=$1 name child
  local -a names
  expect '{' "'{'"
  [[ $where != . ]] && KIND+=(d) PATHS+=("$where") DATA+=("")
  skip_ws
  if [[ ${buf[p-base]} == '}' ]]; then
    (( p++ ))
    return
  fi
  while true; do
    parse_string
    name=$REPLY
    if [[ $where == . ]]; then child=$name; else child=$where/$name; fi
    if [[ -z $name || $name == . || $name == .. || $name == */* || $name == *$'\0'* ]]; then
      die "$child: invalid name"
    fi
    (( ${names[(Ie)$name]} )) && die "$child: duplicate name"
    names+=("$name")
    expect ':' "':'"
    parse_value "$child"
    skip_ws
    case ${buf[p-base]} in
      (',') (( p++ )) ;;
      ('}') (( p++ )); return ;;
      (*) die "invalid JSON at byte $p: expected ',' or '}'" ;;
    esac
  done
}

# ---------------------------------------------------------------- file system
integer ftype   # 0 = missing, 1 = directory, 2 = anything else (never followed)
lstat_type() {
  local -a st
  if zstat -L -A st +mode -- "$1" 2>/dev/null; then
    if (( (st[1] & 8#170000) == 8#040000 )); then ftype=1; else ftype=2; fi
  else
    ftype=0
  fi
}

write_file() {    # write_file <path> <content>
  { print -rn -- "$2" > "$1" } 2>/dev/null || die "$1: cannot write file"
}

apply() {
  integer i
  local f
  local -a st
  for (( i = 1; i <= ${#KIND}; i++ )); do
    f=./${PATHS[i]}
    lstat_type "$f"
    if [[ ${KIND[i]} == d ]]; then
      (( ftype == 1 )) && continue
      (( ftype == 2 )) && { rm -f -- "$f" || die "$f: cannot remove"; }
      mkdir -- "$f" || die "$f: cannot create directory"
      continue
    fi
    (( ftype == 1 )) && die "$f: a directory is in the way"
    (( ftype == 2 )) && { rm -f -- "$f" || die "$f: cannot remove"; }
    case ${KIND[i]} in
      (f) write_file "$f" "${DATA[i]}" ;;
      (x)
        write_file "$f" "${DATA[i]}"
        zstat -L -A st +mode -- "$f" || die "$f: cannot stat"
        chmod $(( [##8] (st[1] & 8#7777) | 8#111 )) "$f" || die "$f: cannot chmod"
        ;;
      (l) ln -s -- "${DATA[i]}" "$f" || die "$f: cannot create symbolic link" ;;
    esac
  done
}

# ---------------------------------------------------------------- main
if (( $# > 0 )); then
  print -ru2 -- "usage: json2dir < document.json"
  exit 2
fi

raw=
integer rs
while true; do
  sysread -i 0 -s 65536 chunk; rs=$?
  (( rs == 0 )) || break
  raw+=$chunk
done
(( rs == 5 )) || die "cannot read standard input"
n=${#raw}
p=1
[[ ${raw[1,3]} == $'\xEF\xBB\xBF' ]] && p=4   # a leading BOM is ignored, as §3 allows
fill

skip_ws
[[ ${buf[p-base]} == '{' ]] || die "the root of the document must be an object"
parse_object .
skip_ws
(( p <= n )) && die "invalid JSON at byte $p: trailing data"

apply
exit 0

#!/usr/bin/env bash
# ============================================
#  yt-fzf.sh の単体テスト
# ============================================
# yt-fzf.sh の関数だけを読み込み（メイン処理は実行されない）、
# 入力の判定・変換など、画面を使わない部分の結果を確かめる。
# fzf / yt-dlp / ffmpeg は不要（使う関数は偽物に差し替える）。
#
# 使い方: bash tests/unit.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  OK   %s\n' "$1"; }
ng()   { FAIL=$((FAIL + 1)); printf '  NG   %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else ng "$1" "期待: [$3] / 実際: [$2]"; fi; }
yes_() { if "${@:2}"; then ok "$1"; else ng "$1"; fi; }
no_()  { if "${@:2}"; then ng "$1"; else ok "$1"; fi; }
section() { printf '\n== %s\n' "$1"; }

# 読み込み時に ~/.yt-downloader を作るので、本物のホームを汚さないよう一時フォルダにする
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
STUB="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME" "$STUB"' EXIT
# 読み込み時の「fzf --no-input」などの確認で本物を呼ばないよう、何もしない fzf を先に置く
printf '#!/bin/sh\nexit 1\n' > "$STUB/fzf"; chmod +x "$STUB/fzf"
PATH="$STUB:$PATH"

# shellcheck source=../yt-fzf.sh
source "${ROOT_DIR}/yt-fzf.sh"
trap 'rm -rf "$TEST_HOME" "$STUB"; cleanup' EXIT

# --------------------------------------------
section "読み込み"
eq "source してもメイン処理は動かない（版だけ読める）" "${VERSION:-}" "$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${ROOT_DIR}/yt-fzf.sh")"
yes_ "設定ファイルのひな形を作る" test -f "$HOME/.yt-downloader/config"

# --------------------------------------------
section "時間の入力 (_is_valid_time / _to_seconds / _fmt_time)"
for t in 0 90 1:30 01:30 1:20:00 12:05:09; do yes_ "「$t」は正しい" _is_valid_time "$t"; done
for t in "" 1:3 1:300 a:00 1:2:3:4 -1; do no_ "「$t」は誤り" _is_valid_time "$t"; done
eq "08:09 は 489 秒（8進数と誤解しない）" "$(_to_seconds 08:09)" "489"
eq "1:20:00 は 4800 秒"                    "$(_to_seconds 1:20:00)" "4800"
eq "65 秒は 1:05"                          "$(_fmt_time 65)" "1:05"
eq "3725 秒は 1:02:05"                     "$(_fmt_time 3725)" "1:02:05"

# --------------------------------------------
section "URL の判定 (is_collection_url)"
for u in "https://www.youtube.com/watch?v=abc" "https://youtu.be/abc" \
         "https://www.youtube.com/shorts/abc" "https://www.youtube.com/watch?v=abc&list=PL1" \
         "https://www.youtube.com/live/abc"; do
  no_ "動画1本: $u" is_collection_url "$u"
done
for u in "https://www.youtube.com/playlist?list=PL1" "https://www.youtube.com/@someone" \
         "https://www.youtube.com/@someone/videos" "https://www.youtube.com/channel/UC1"; do
  yes_ "プレイリスト・チャンネル: $u" is_collection_url "$u"
done

# --------------------------------------------
section "貼り付けたパスの整形 (_clean_path)"
eq "引用符を外す"                  "$(_clean_path "  '/tmp/a b.mp3'  ")" "/tmp/a b.mp3"
eq "file:// と %20 を戻す"         "$(_clean_path 'file:///tmp/a%20b.mp3')" "/tmp/a b.mp3"
# shellcheck disable=SC2088  # 入力された文字の「~」をそのまま渡している
eq "~ をホームにする"              "$(_clean_path '~/x.mp3')" "${HOME}/x.mp3"
eq "\\ でエスケープされた空白を戻す" "$(_clean_path '/tmp/a\ b.mp3')" "/tmp/a b.mp3"

# --------------------------------------------
section "ファイル名 (_trim_bytes / _unique_path)"
long=$(printf 'あ%.0s' {1..100})   # 300 バイト
t=$(_trim_bytes "$long" 180)
eq "日本語を文字の途中で切らずに 180 バイト以内にする" "$(printf '%s' "$t" | wc -c)" "180"
d=$(mktemp -d); touch "$d/曲.mp3" "$d/曲 (2).mp3"
eq "同じ名前があれば番号を付ける" "$(_unique_path "$d" 曲 mp3)" "$d/曲 (3).mp3"
rm -rf "$d"

# --------------------------------------------
section "設定ファイルの読み込み (load_config)"
cat > "$CONFIG_FILE" << 'EOF'
SEARCH_COUNT=30
STREAM_FORMAT = 'bv*[height<=720]+ba/b'
CD_MAX_SECONDS=abc
LISTEN_FORMAT=
EVIL=$(touch /tmp/should-not-exist)
EOF
SEARCH_COUNT=15; CD_MAX_SECONDS=4800; LISTEN_FORMAT='ba/b'
load_config
eq "数値の項目を読む"                 "$SEARCH_COUNT" "30"
eq "空白と引用符を許す"               "$STREAM_FORMAT" 'bv*[height<=720]+ba/b'
eq "数字でない値は無視する"           "$CD_MAX_SECONDS" "4800"
eq "空の値は無視する"                 "$LISTEN_FORMAT" "ba/b"
no_ "知らない項目は実行しない"        test -e /tmp/should-not-exist
printf 'SEARCH_COUNT=999\n' > "$CONFIG_FILE"; SEARCH_COUNT=15; load_config
eq "範囲外の件数は無視する"           "$SEARCH_COUNT" "15"

# --------------------------------------------
section "CD-Text (_cdtext_str / _write_toc)"
if command -v iconv &>/dev/null; then
  eq "Shift_JIS で表せない文字（絵文字）を除く" "$(_cdtext_str '曲🎵名')" "曲名"
fi
eq "TOC を壊す \" を置き換える"       "$(_cdtext_str 'say "hi"')" "say 'hi'"
toc=$(mktemp)
_write_toc "$toc" "" yes $'/t/01.wav\t一曲目\tA' $'/t/02.wav\t\t'
yes_ "空の CD タイトルは「CD 日付」"      grep -q "TITLE \"CD $(date +%Y-%m-%d)\"" "$toc"
yes_ "空の曲名は「トラック 番号」"        grep -q 'TITLE "トラック 2"' "$toc"
yes_ "アーティストが1人ならその人で埋める" test "$(grep -c 'PERFORMER "A"' "$toc")" -eq 3
rm -f "$toc"

# --------------------------------------------
section "クリップボード (copy_to_clipboard)"
# wl-copy と xclip の両方が入った X11 では、xclip でコピーできること
printf '#!/bin/sh\nexit 1\n' > "$STUB/wl-copy"
printf '#!/bin/sh\ncat > "%s/clip"\n' "$STUB" > "$STUB/xclip"
chmod +x "$STUB/wl-copy" "$STUB/xclip"
( unset WAYLAND_DISPLAY; DISPLAY=:0 copy_to_clipboard "https://x" )
eq "X11 では wl-copy が入っていても xclip を使う" "$(cat "$STUB/clip" 2>/dev/null)" "https://x"
rm -f "$STUB/clip"
( WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 copy_to_clipboard "https://y" )
eq "wl-copy が失敗したら次を試す"                 "$(cat "$STUB/clip" 2>/dev/null)" "https://y"
rm -f "$STUB/wl-copy" "$STUB/xclip"
if command -v pbcopy &>/dev/null; then :; else
  ( unset WAYLAND_DISPLAY DISPLAY; copy_to_clipboard "z" ); eq "ツールが無ければ失敗を返す" "$?" "1"
fi

# --------------------------------------------
section "yt-dlp の更新方法の案内 (ytdlp_update_cmd)"
mkdir -p "$STUB/pipx/venvs/yt-dlp/bin" "$STUB/pip" "$STUB/bin"
printf '#!/usr/bin/python3\n' > "$STUB/pipx/venvs/yt-dlp/bin/yt-dlp"
printf '#!/usr/bin/python3\n' > "$STUB/pip/yt-dlp"
printf '\x7fELF' > "$STUB/bin/yt-dlp"
chmod +x "$STUB/pipx/venvs/yt-dlp/bin/yt-dlp" "$STUB/pip/yt-dlp" "$STUB/bin/yt-dlp"
# 各ケースは ( ) の中で PATH を差し替える（外の PATH は変えない）
# shellcheck disable=SC2030,SC2031
_cmd() { ( pacman() { return 1; }; PATH="$1:$PATH"; ytdlp_update_cmd ); }
eq "pipx で入れた → pipx upgrade"  "$(_cmd "$STUB/pipx/venvs/yt-dlp/bin")" "pipx upgrade yt-dlp"
eq "pip で入れた → pip install -U" "$(_cmd "$STUB/pip")" 'python3 -m pip install -U "yt-dlp[default]"'
eq "配布バイナリ → yt-dlp -U"      "$(_cmd "$STUB/bin")" "yt-dlp -U"
# shellcheck disable=SC2030,SC2031
eq "pacman で入れた → pacman -Syu" "$( ( pacman() { return 0; }; PATH="$STUB/bin:$PATH"; ytdlp_update_cmd ) )" "sudo pacman -Syu yt-dlp"

# --------------------------------------------
section "JavaScript 実行環境の案内 (notice_js_runtime)"
rm -f "$JS_RUNTIME_NOTICE_FILE"
out=$( ( has_js_runtime() { return 1; }; notice_js_runtime < /dev/null ) )
yes_ "deno が無ければ案内する"        grep -q 'deno' <<< "$out"
out=$( ( has_js_runtime() { return 1; }; notice_js_runtime < /dev/null ) )
eq "案内は一度だけ"                   "$out" ""
( has_js_runtime() { return 0; }; notice_js_runtime )
no_ "deno が入ったら記録を消す（また無くなったら案内する）" test -f "$JS_RUNTIME_NOTICE_FILE"

# --------------------------------------------
section "版の一致"
eq "yt-fzf.sh の VERSION と PKGBUILD の pkgver が同じ" "$VERSION" "$(sed -n 's/^pkgver=//p' "${ROOT_DIR}/PKGBUILD")"

printf '\n結果: 成功 %d 件 / 失敗 %d 件\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

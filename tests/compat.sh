#!/usr/bin/env bash
# ============================================
#  最新のツールとの互換性チェック
# ============================================
# yt-fzf.sh が使っている yt-dlp / fzf / mpv / ffmpeg のオプション・フィルタ・
# エンコーダーと、PKGBUILD の依存パッケージが、いま入っている版でも
# 使えるかを確かめる。GitHub Actions で毎週、最新の Arch Linux で実行する。
#
# 【目的】yt-fzf.sh を変えていなくても、ツール側の変更（オプションの改名・削除、
# パッケージ名の変更など）で動かなくなることがある。使う人が気付く前に知るためのもの。
#
# 【重要】yt-fzf.sh に新しいオプションを書いたら、下の一覧のどれかに足すこと。
# 一覧に無いオプションが本体に出てくると「どのツールのものか分からない」として失敗する
# （確認漏れのまま増えていくのを防ぐため）。
#
# 使い方: bash tests/compat.sh
#   Arch Linux 上で、yt-dlp fzf mpv ffmpeg（あれば cdrdao）を入れた状態で実行する。
#   YouTube への接続はしない（GitHub の実行環境からはアクセスが制限されやすいため）。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/yt-fzf.sh"
FAIL=0
WARN=0

ok()   { printf '  OK   %s\n' "$1"; }
ng()   { FAIL=$((FAIL + 1)); printf '  NG   %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
         [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::error title=互換性チェック::$1${2:+ — $2}"; return 0; }
warn() { WARN=$((WARN + 1)); printf '  注意 %s\n' "$1"
         [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::warning title=互換性チェック::$1"; return 0; }
section() { printf '\n== %s\n' "$1"; }

for c in yt-dlp fzf mpv ffmpeg ffprobe python3 pacman; do
  command -v "$c" &>/dev/null || { echo "必要なコマンドがありません: $c" >&2; exit 2; }
done

# --- どのツールのオプションか ---
# 1つのオプションが複数のツールにあってもよい（--color は yt-dlp と fzf の両方）
YTDLP_LONG=(audio-format audio-quality color download-sections embed-metadata flat-playlist
  force-keyframes-at-cuts ignore-no-formats-error js-runtimes match-filters merge-output-format
  newline no-mtime no-playlist no-warnings playlist-items postprocessor-args print print-to-file
  progress skip-download socket-timeout windows-filenames)
YTDLP_SHORT=(q f o S x P)
# fzf は「オプション 値」の形で、実際に渡している値の例を書く（値が要らないものは名前だけ）
FZF_ARGS=(
  "--no-info" "--cycle" "--layout=reverse" "--border=double" "--border-label= x "
  "--border-label-pos=top" "--color=fg+:#00ffff,bg+:#1a1a2e,hl:#af5fff"
  "--color=border:#00ffff,label:#00ffff,header:#af5fff"
  "--color=prompt:#af5fff,pointer:#00ffff,marker:#46eb34" "--color=spinner:#00ffff,info:#af5fff"
  "--prompt= > " "--pointer= >" "--margin=1" "--padding=1" "--no-input" "--header=x"
  "--header-first" "--no-sort" "--height=50%" "--print-query" "--query=" "--multi"
  "--delimiter=\t" "--with-nth=1"
)
FZF_OPTIONAL=("--gutter= ")   # 古い fzf では使わない（yt-fzf.sh 側で有無を確かめている）
MPV_LONG=(cache demuxer-max-back-bytes demuxer-max-bytes force-window geometry keep-open title)
CDRDAO_LONG=(device eject)
XSEL_LONG=(clipboard input)
OWN_LONG=(help version)

# --------------------------------------------
section "本体に出てくるオプションの分類"
mapfile -t used < <(grep -vE '^[[:space:]]*#' "$SCRIPT" \
  | grep -oE '(^|[[:space:]"(=])--[a-z][a-z0-9-]*' | sed -E 's/^[[:space:]"(=]*--//' | sort -u)
known=" ${YTDLP_LONG[*]} ${MPV_LONG[*]} ${CDRDAO_LONG[*]} ${XSEL_LONG[*]} ${OWN_LONG[*]} gutter "
for a in "${FZF_ARGS[@]}"; do a="${a#--}"; known+=" ${a%%=*} "; done
unknown=()
for o in "${used[@]}"; do [[ "$known" == *" $o "* ]] || unknown+=("--$o"); done
if [[ ${#unknown[@]} -eq 0 ]]; then
  ok "本体の ${#used[@]} 種類のオプションは、すべて確認の対象に入っている"
else
  ng "確認の対象に入っていないオプションがある: ${unknown[*]}" "tests/compat.sh の一覧に追加してください"
fi

# --------------------------------------------
section "yt-dlp $(yt-dlp --version 2>/dev/null)"
# オプション名は「途中まで打った名前を補う」仕組みに頼らず、正式名と完全に一致するかを見る。
# ヘルプに出ない（非表示の古い名前になった）ものは注意として出す。
py_out=$(python3 - "${YTDLP_LONG[@]}" -- "${YTDLP_SHORT[@]}" << 'PY'
import optparse, sys
from yt_dlp.options import create_parser
args = sys.argv[1:]
i = args.index('--')
longs, shorts = args[:i], args[i + 1:]
p = create_parser()
for name in longs:
    opt = p._long_opt.get('--' + name)
    if opt is None:
        print(f'NG --{name}')
    elif opt.help == optparse.SUPPRESS_HELP:
        print(f'HIDDEN --{name}')
for name in shorts:
    if '-' + name not in p._short_opt:
        print(f'NG -{name}')
PY
)
if [[ -z "$py_out" ]]; then
  ok "使っている ${#YTDLP_LONG[@]} 個の長いオプションと ${#YTDLP_SHORT[@]} 個の短いオプションが、すべて正式名で存在する"
else
  while read -r kind name; do
    case "$kind" in
      NG)     ng "yt-dlp にオプション $name が無い（改名・削除された可能性）" ;;
      HIDDEN) warn "yt-dlp の $name はヘルプに出ない古い名前になっている（新しい名前への書き換えを推奨）" ;;
    esac
  done <<< "$py_out"
fi

# 実際に渡している引数の組み合わせを、yt-dlp 自身の解析にかける（値の誤りも見つかる）
STREAM_FORMAT=$(sed -n "s/^STREAM_FORMAT='\(.*\)'$/\1/p" "$SCRIPT")
LISTEN_FORMAT=$(sed -n "s/^LISTEN_FORMAT='\(.*\)'$/\1/p" "$SCRIPT")
LOUDNORM=$(sed -n 's/^LOUDNORM_FILTER="\(.*\)"$/\1/p' "$SCRIPT")
py_out=$(python3 - "$STREAM_FORMAT" "$LISTEN_FORMAT" "$LOUDNORM" << 'PY' 2>&1
import sys
import yt_dlp
stream_fmt, listen_fmt, loudnorm = sys.argv[1:4]
cases = {
    '再生': ['-q', '--no-warnings', '--no-playlist', '--socket-timeout', '10',
             '-f', stream_fmt, '--merge-output-format', 'mkv', '-o', '-'],
    '音声のみ再生': ['-f', listen_fmt],
    '配信の確認': ['--no-playlist', '--playlist-items', '1', '--skip-download',
                   '--ignore-no-formats-error', '--no-warnings', '--print', '%(live_status|)s'],
    '動画保存': ['-P', '/tmp', '-S', 'res:1080,vcodec:h264,acodec:m4a', '--merge-output-format', 'mp4',
                 '--no-playlist', '--playlist-items', '1',
                 '--match-filters', 'live_status!=?is_live & live_status!=?is_upcoming',
                 '--embed-metadata', '--windows-filenames', '--no-mtime', '--progress', '--newline',
                 '--download-sections', '*0:00-1:00', '--force-keyframes-at-cuts',
                 '--print-to-file', 'after_move:filepath', '/tmp/x', '-o', '%(title).200B.%(ext)s'],
    '最高画質': ['-S', 'res,fps,vcodec,acodec'],
    '音声保存': ['-x', '--audio-format', 'mp3', '--audio-quality', '0',
                 '--postprocessor-args', f'ExtractAudio:-af {loudnorm} -ar 48000'],
    '音声保存（M4A）': ['-x', '--audio-format', 'm4a', '-S', 'acodec:m4a'],
    '検索': ['--color', 'no_color', '--flat-playlist', '--print',
             '[%(uploader,channel|不明)s] %(title)s [%(duration_string|)s]\t%(id)s\t%(live_status|)s'],
}
for fmt in ('mp3', 'm4a', 'best', 'wav', 'flac'):
    cases[f'音声形式 {fmt}'] = ['-x', '--audio-format', fmt]
for name, argv in cases.items():
    try:
        opts = yt_dlp.parse_options(argv + ['--ignore-config', 'https://example.invalid/'])
        if '-f' in argv:
            with yt_dlp.YoutubeDL({'quiet': True}) as ydl:
                ydl.build_format_selector(argv[argv.index('-f') + 1])
        if '--match-filters' in argv:
            yt_dlp.utils.match_filter_func(argv[argv.index('--match-filters') + 1])
    except SystemExit as e:
        print(f'NG {name}: 引数の解析で終了しました（{e}）')
    except Exception as e:
        print(f'NG {name}: {type(e).__name__}: {e}')
    else:
        print(f'OK {name}')
PY
)
while IFS= read -r line; do
  case "$line" in
    OK\ *) ok "引数の組み合わせ「${line#OK }」を yt-dlp が受け付ける" ;;
    NG\ *) ng "引数の組み合わせ「${line#NG }」" ;;
    *)     [[ -n "$line" ]] && printf '       %s\n' "$line" ;;
  esac
done <<< "$py_out"

# YouTube 用の JavaScript 実行環境（Arch では yt-dlp の依存で入るはず）
if command -v deno &>/dev/null; then
  ok "deno がある（$(deno --version 2>/dev/null | head -n1)）"
else
  warn "deno が無い（Arch の yt-dlp の依存関係が変わった可能性。README と PKGBUILD の説明を見直す）"
fi

# --------------------------------------------
section "fzf $(fzf --version 2>/dev/null | awk '{print $1}')"
for a in "${FZF_ARGS[@]}"; do
  if fzf "$a" --version &>/dev/null; then ok "fzf ${a%%=*}"; else ng "fzf がオプション ${a%%=*} を受け付けない"; fi
done
for a in "${FZF_OPTIONAL[@]}"; do
  if fzf "$a" --version &>/dev/null; then ok "fzf ${a%%=*}（新しい fzf のみ）"; else warn "fzf ${a%%=*} が使えない（古い fzf として扱われ、見た目だけ変わる）"; fi
done

# --------------------------------------------
section "mpv $(mpv --version 2>/dev/null | head -n1 | awk '{print $2}')"
mpv_opts=$(mpv --list-options 2>/dev/null)
for o in "${MPV_LONG[@]}"; do
  if grep -qE "^[[:space:]]*--${o}([[:space:]]|$)" <<< "$mpv_opts"; then ok "mpv --$o"; else ng "mpv にオプション --$o が無い"; fi
done

# --------------------------------------------
section "ffmpeg $(ffmpeg -version 2>/dev/null | head -n1 | awk '{print $3}')"
encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for e in libmp3lame aac libopus flac pcm_s16le wmav2 libvpx-vp9 libx264; do
  if grep -qE "^ [A-Z.]{6} ${e}( |$)" <<< "$encoders"; then ok "エンコーダー $e"; else ng "ffmpeg にエンコーダー $e が無い"; fi
done
# フィルタと、指定しているフィルタのオプション
declare -A FILTER_OPTS=([loudnorm]="I TP LRA" [alimiter]="limit level" [apad]="whole_dur" [volume]="volume")
for f in "${!FILTER_OPTS[@]}"; do
  help=$(ffmpeg -hide_banner -h "filter=$f" 2>/dev/null)
  if ! grep -q "Filter $f" <<< "$help"; then ng "ffmpeg にフィルタ $f が無い"; continue; fi
  for o in ${FILTER_OPTS[$f]}; do
    if grep -qE "^[[:space:]]+${o}[[:space:]]" <<< "$help"; then ok "フィルタ $f の $o"; else ng "フィルタ $f にオプション $o が無い"; fi
  done
done
if ffmpeg -hide_banner -h muxer=mp4 2>/dev/null | grep -q faststart; then ok "mp4 の -movflags +faststart"; else ng "mp4 の faststart が無い"; fi
# 実際に変換を通してみる（短い無音で、CD 用 WAV と音量正規化の組み合わせ）
tmp=$(mktemp -d)
if ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
     -af "$LOUDNORM,apad=whole_dur=4" -c:a pcm_s16le -ac 2 -ar 44100 "$tmp/t.wav" \
   && [[ "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/t.wav" | cut -d. -f1)" == "4" ]]; then
  ok "音量正規化と CD 用 WAV（4 秒に延ばす）の変換が通る"
else
  ng "音量正規化と CD 用 WAV の変換に失敗した"
fi
rm -rf "$tmp"

# --------------------------------------------
section "cdrdao（音楽CD）"
if command -v cdrdao &>/dev/null; then
  cd_help=$(cdrdao write 2>&1)
  for o in "${CDRDAO_LONG[@]}"; do
    if grep -q -- "--$o" <<< "$cd_help"; then ok "cdrdao write --$o"; else ng "cdrdao write にオプション --$o が無い"; fi
  done
else
  warn "cdrdao が入っていないので確認を省略した"
fi

# --------------------------------------------
section "PKGBUILD の依存パッケージ"
mapfile -t deps < <(
  # shellcheck disable=SC1091  # PKGBUILD は実行時に読む
  ( source "${ROOT_DIR}/PKGBUILD"; printf '%s\n' "${depends[@]}" "${optdepends[@]%%:*}" ) | sort -u)
for d in "${deps[@]}"; do
  if pacman -Si -- "$d" &>/dev/null; then
    ok "$d"
  elif LC_ALL=C pacman -Sp --noconfirm --print-format '%n' -- "$d" &>/dev/null < /dev/null; then
    warn "$d は旧名（別のパッケージが引き継いでいる）。新しい名前への書き換えを推奨"
  else
    ng "公式リポジトリに $d が無い（PKGBUILD の depends / optdepends を見直す）"
  fi
done

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "結果: 問題 ${FAIL} 件 / 注意 ${WARN} 件"
  exit 1
fi
echo "結果: 問題なし（注意 ${WARN} 件）"

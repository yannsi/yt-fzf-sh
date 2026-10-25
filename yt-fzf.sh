#!/bin/bash
#
# yt-fzf - fzf のメニューで YouTube 動画を検索・再生・保存するツール
#
# Copyright (c) 2026 yannsi
# SPDX-License-Identifier: MIT
# ライセンス全文は同梱の LICENSE を参照してください。

# --- 設定 ---
# バージョン（PKGBUILD の pkgver と同じ値にする）
VERSION="1.2.2"

CONFIG_DIR="${HOME}/.yt-downloader"
LAST_DIR_FILE="${CONFIG_DIR}/.last_dir"
DEFAULT_DIR="${HOME}/Downloads"

mkdir -p "$CONFIG_DIR"

# 保存先を読み込み
if [ -f "$LAST_DIR_FILE" ]; then
    TARGET_DIR=$(cat "$LAST_DIR_FILE")
    [ ! -d "$TARGET_DIR" ] && TARGET_DIR="$DEFAULT_DIR"
else
    TARGET_DIR="$DEFAULT_DIR"
fi
[ ! -d "$TARGET_DIR" ] && TARGET_DIR="$HOME"

# --- デザイン設定 (Neon Cyber Theme) ---
C_MAIN="51"       # Neon Cyan
C_ERR="196"       # Neon Red
C_OK="46"         # Neon Green

# fzf 共通オプション
FZF_OPTS=(
    --no-info
    --cycle
    --layout=reverse
    --border=double
    --border-label=" [ YT-DOWNLOADER v${VERSION} ] "
    --border-label-pos=top
    --color="fg+:#00ffff,bg+:#1a1a2e,hl:#af5fff"
    --color="border:#00ffff,label:#00ffff,header:#af5fff"
    --color="prompt:#af5fff,pointer:#00ffff,marker:#46eb34"
    --color="spinner:#00ffff,info:#af5fff"
    --prompt=" > "
    --pointer=" >"
    --margin=1
    --padding=1
)

# メニュー（項目を選ぶだけの画面）では文字の入力欄を隠す。
# 入力欄があると、入力欄のカーソルと選択中の項目の2か所にフォーカスがあるように見えるため。
# --no-input は fzf 0.59 以降の機能。古い fzf ではこれまでどおり入力欄を表示する。
FZF_MENU_OPTS=()
if fzf --no-input --version &>/dev/null; then
    FZF_MENU_OPTS=(--no-input)
fi

# fzf 0.66 以降は、選択中の行の左端（ガター）に「▌」が出るようになった。
# この配色では選択中の行の背景色で十分に分かるので、空白にして隠す。
# --gutter は 0.66 以降の機能。古い fzf ではこれまでどおり何も足さない。
if fzf --gutter ' ' --version &>/dev/null; then
    FZF_OPTS+=(--gutter ' ')
fi

# 音量正規化の目標値（EBU R128 系。-16 LUFS はスマホ・PC での視聴向け）
LOUDNORM_FILTER="loudnorm=I=-16:TP=-1.5:LRA=11"

# ファイル名に使うタイトルの最大バイト数。
# Linux のファイル名は 255 バイトまで。日本語は1文字3バイトなので、
# 長いタイトルだと 85 文字前後で「File name too long」になる。
# 時間範囲・拡張子・作業用の一時名（.part など）が付く分の余裕を残して切り詰める。
TITLE_MAX_BYTES=200        # 全体ダウンロード
TITLE_MAX_BYTES_RANGE=180  # 範囲指定（ファイル名に時間範囲が付く分を差し引く）

# 手元のファイル（LOCAL）の一覧に出す、音声・動画ファイルの拡張子
LOCAL_EXTS="mp3|m4a|aac|opus|ogg|oga|wav|flac|wma|webm|mp4|mkv|mov|m4v|avi"

# --- 好みで変えられる設定（~/.yt-downloader/config に書くと、こちらより優先される） ---
# ストリーミング再生（STREAM）で取得する画質（yt-dlp の -f と同じ書き方）
STREAM_FORMAT='bv*[height<=1080]+ba/b'
# 音声のみ再生（LISTEN）で取得する形式
LISTEN_FORMAT='ba/b'
# 検索結果の件数
SEARCH_COUNT=15
# 音楽CDに入る時間の上限（秒）。一般的な 80 分の CD-R は 4800 秒（74 分の CD-R は 4440 秒）
CD_MAX_SECONDS=4800

# 設定ファイル。パッケージで入れた本体（/usr/bin/yt-fzf）は更新のたびに上書きされるため、
# 好みの設定は本体ではなくこのファイルに書く。無ければ説明付きのひな形を作る。
CONFIG_FILE="${CONFIG_DIR}/config"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" 2>/dev/null <<'CONF'
# yt-fzf の設定ファイル
# 変えたい行の先頭の「#」を消して、値を書き換えてください。
# 書いていない項目は、標準の値が使われます。

# ストリーミング再生（STREAM）の画質。720p までにするなら height<=720
#STREAM_FORMAT='bv*[height<=1080]+ba/b'

# 音声のみ再生（LISTEN）の形式
#LISTEN_FORMAT='ba/b'

# 検索結果の件数（1〜50）
#SEARCH_COUNT=15

# 音楽CDに入る時間の上限（秒）。80 分の CD-R は 4800、74 分の CD-R は 4440
#CD_MAX_SECONDS=4800
CONF
fi

# 設定ファイルを読み込む。
# source で実行はせず、決まった項目の「名前=値」だけを読む（書き間違いで本体が壊れないように）
load_config() {
    [ -f "$CONFIG_FILE" ] || return
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%"${value##*[![:space:]]}"}"   # 末尾の空白を除く
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        case "$key" in
            STREAM_FORMAT|LISTEN_FORMAT)
                [ -n "$value" ] && printf -v "$key" '%s' "$value" ;;
            SEARCH_COUNT)
                [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 50 )) && SEARCH_COUNT="$value" ;;
            CD_MAX_SECONDS)
                [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) && CD_MAX_SECONDS="$value" ;;
        esac
    done < "$CONFIG_FILE"
}
load_config

# --- 関数定義 ---

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "\033[38;5;196m[ ERROR ] 必須ツール '$1' がインストールされていません。\033[0m"
        if [ "$1" == "ffmpeg" ]; then
            echo "動画の結合や音声変換に必要です。パッケージマネージャでインストールしてください。"
        fi
        exit 1
    fi
}

# YouTube 用の JavaScript 実行環境（deno）があるか確かめる。
# 【経緯】2025年11月から、yt-dlp は YouTube の暗号を解くのに外部の JavaScript
# 実行環境を使うようになった。無いと選べる画質がかなり減り、将来は YouTube 自体が
# 使えなくなる予定。yt-dlp が既定で使うのは deno だけ（node などは yt-dlp の設定で
# --js-runtimes を書いたときだけ使われる）。
# Arch では yt-dlp → yt-dlp-ejs → deno と依存で自動的に入るので、まず困らない。
# 他のディストリビューションで入っていない場合に気付けるよう、起動時に一度だけ知らせる。
# （再生時は --no-warnings を付けているので、yt-dlp 自身の警告は画面に出ない）
JS_RUNTIME_NOTICE_FILE="${CONFIG_DIR}/.js_runtime_notice_shown"
has_js_runtime() {
    command -v deno &>/dev/null
}
notice_js_runtime() {
    has_js_runtime && { rm -f "$JS_RUNTIME_NOTICE_FILE"; return 0; }
    [ -f "$JS_RUNTIME_NOTICE_FILE" ] && return 0
    echo -e "\033[38;5;214m[ 注意 ] YouTube 用の JavaScript 実行環境（deno）が見つかりません。\033[0m"
    echo "  このままでも動きますが、選べる画質が少なくなったり、再生・保存に失敗したりします。"
    echo "  deno をインストールしてください（Arch: sudo pacman -S deno）。"
    echo "  node などを使う場合は、yt-dlp の設定ファイルに --js-runtimes を書いてください。"
    echo "  （この案内は一度だけ表示します。キーを押すと続けます）"
    : > "$JS_RUNTIME_NOTICE_FILE" 2>/dev/null
    read -rsn 1
}
# 失敗したときの案内に付け足す一言（deno が無いときだけ）
js_runtime_hint() {
    has_js_runtime || echo "（deno が入っていないことも原因として考えられます: README の「必要なもの」を参照）"
}

# 一時ファイルを作成
TEMP_RESULT=$(mktemp)   # 検索結果
TEMP_LIST=$(mktemp)     # fzf に渡す一覧
TEMP_ERR=$(mktemp)      # 検索時のエラー出力
TEMP_PATHS=$(mktemp)    # 保存されたファイルのパス
TEMP_MARKER=$(mktemp)   # ダウンロード開始時刻の目印（スキップ判定用）
TEMP_PLAYLOG=$(mktemp)  # 再生時の mpv の出力（失敗したときの表示用）
TEMP_CD_DIR=""          # 音楽CDに書き込む WAV を置く一時フォルダ（書き込むときだけ作る）

cleanup() {
    rm -f "$TEMP_RESULT" "$TEMP_LIST" "$TEMP_ERR" "$TEMP_PATHS" "$TEMP_MARKER" "$TEMP_PLAYLOG"
    [ -n "$TEMP_CD_DIR" ] && rm -rf "$TEMP_CD_DIR"
}
trap cleanup EXIT

do_exit() {
    clear; exit 0
}

fzf_menu() {
    # 引数: ヘッダー文字列、続けて選択肢を渡す
    local header="$1"; shift
    printf '%s\n' "$@" | fzf "${FZF_OPTS[@]}" "${FZF_MENU_OPTS[@]}" \
        --header="$header" \
        --header-first \
        --no-sort \
        --height=50%
}

show_status() {
    # 色付きステータス行を表示
    local color="$1"; shift
    echo -e "\033[38;5;${color}m $* \033[0m"
}

wait_key() {
    echo "キーを押すとメニューに戻ります..."
    read -rsn 1
    # 矢印キーなどは1回押すと複数の文字（例: ↓ = ESC [ B）が届く。
    # 1文字目しか読んでいないので、残りが次のメニューの検索欄に入力されて
    # メニューが空に見えてしまう。残っている入力はここで読み捨てる。
    while read -rsn 1 -t 0.05; do :; done
    # 結果表示やエラーが次のメニューの上に残り続けないよう、画面を消してから戻る
    clear
}

# 利用可能なクリップボードツールで文字列をコピーする。
# コピーできたら 0、ツールが無ければ 1 を返す。
# 【重要】見つかった最初のツールだけで諦めないこと。wl-clipboard と xclip の
# 両方が入った X11 のデスクトップでは、wl-copy が先に選ばれて失敗し、
# 「クリップボードツールが見つかりません」と誤って表示されていた。
# 今の画面の種類（Wayland / X11）で使えるものから順に試し、だめなら次を試す。
copy_to_clipboard() {
    local text="$1"
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy &>/dev/null; then
        printf '%s' "$text" | wl-copy 2>/dev/null && return 0
    fi
    if [ -n "${DISPLAY:-}" ]; then
        if command -v xclip &>/dev/null; then
            printf '%s' "$text" | xclip -selection clipboard 2>/dev/null && return 0
        fi
        if command -v xsel &>/dev/null; then
            printf '%s' "$text" | xsel --clipboard --input 2>/dev/null && return 0
        fi
    fi
    if command -v pbcopy &>/dev/null; then
        printf '%s' "$text" | pbcopy && return 0
    fi
    return 1
}

# 動画1本ではなく、プレイリストやチャンネル全体を指す URL かどうかを判定する。
# （--no-playlist は「動画＋プレイリスト」の URL にしか効かず、
#   playlist?list=… やチャンネルの URL だと全動画をダウンロードしてしまうため）
# 全体を指す URL なら 0、動画1本（または判断できない）なら 1 を返す。
is_collection_url() {
    local url="$1"
    # watch?v=… / youtu.be/… / shorts/… / live/… / embed/… は動画1本
    # （&list= が付いていても、保存されるのはその1本だけ）
    [[ "$url" =~ ([?\&]v=|youtu\.be/|/shorts/|/live/|/embed/) ]] && return 1
    [[ "$url" =~ ([?\&]list=|/playlist|/@|/channel/|/c/|/user/) ]]
}

# 時間(秒 / 分:秒 / 時:分:秒)が正しい形式かどうかを判定
_is_valid_time() {
    [[ "$1" =~ ^(([0-9]+:)?[0-9]{1,2}:[0-9]{2}|[0-9]+)$ ]]
}

# 時間を秒数に変換（"08" などを 8 進数と誤解しないよう 10# を付ける）
_to_seconds() {
    local total=0 part
    local -a parts
    IFS=: read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        total=$(( total * 60 + 10#$part ))
    done
    echo "$total"
}

# 「開始-終了」の形式でまとめて範囲を入力させる。
# 例: 0:00-1:00 / 1:20:00-1:25:30
# 空入力(ESC)なら空文字を返す。不正な形式なら再入力を求める。
# ※ 結果は標準出力で返すため、エラー表示は標準エラー(>&2)に出す。
prompt_range_input() {
    local input start end
    while true; do
        input=$(echo "" | fzf "${FZF_OPTS[@]}" \
            --header="範囲を「開始-終了」で入力  例: 0:00-1:00 / 1:20:00-1:25:30（ESCで戻る）" \
            --header-first --height=30% --print-query --no-sort --query="" | tail -1)

        # スペースを除去し、全角の区切り文字（：〜～－）を半角に揃える
        input="${input//[[:space:]]/}"
        input="${input//：/:}"
        input="${input//〜/-}"
        input="${input//～/-}"
        input="${input//－/-}"

        if [ -z "$input" ]; then
            echo ""
            return
        fi

        if [[ "$input" != *-* ]]; then
            show_status "$C_ERR" "「開始-終了」のように - (ハイフン) で区切って入力してください　例: 0:00-1:00" >&2
            sleep 1.5
            continue
        fi

        start="${input%-*}"
        end="${input##*-}"

        if ! _is_valid_time "$start" || ! _is_valid_time "$end"; then
            show_status "$C_ERR" "時間の形式が正しくありません。分:秒（例 1:30）または 時:分:秒（例 1:20:00）で入力してください" >&2
            sleep 1.5
            continue
        fi

        if (( $(_to_seconds "$start") >= $(_to_seconds "$end") )); then
            show_status "$C_ERR" "終了時間は開始時間より後にしてください　例: 0:30-1:00" >&2
            sleep 1.5
            continue
        fi

        echo "${start}-${end}"
        return
    done
}

# フォルダのみを選択する独自ブラウザ
# ※ $( ) の中(サブシェル)で呼ばれるため、ここで exit してもツール全体は終了しない。
#    EXIT が選ばれたら目印 "__EXIT__" を返し、呼び出し側で終了する。
select_directory() {
    local current_dir="$1"
    local temp_dir="$current_dir"
    [ ! -d "$temp_dir" ] && temp_dir="$HOME"

    while true; do
        local CHOICE
        # find で1行1フォルダずつ出すので、スペースを含む名前でも分割されない
        CHOICE=$({
            printf '%s\n' \
                "BACK     戻る (変更しない)" \
                "SELECT   このフォルダに決定" \
                "UP       .. (上の階層へ)" \
                "EXIT     終了"
            find "$temp_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort
        } | fzf "${FZF_OPTS[@]}" \
                --header="保存先フォルダの選択  |  現在: $temp_dir" \
                --header-first \
                --no-sort \
                --height=60%)

        case "$CHOICE" in
            "BACK     戻る (変更しない)")
                echo "$current_dir"; return ;;
            "SELECT   このフォルダに決定")
                echo "$temp_dir"; return ;;
            "UP       .. (上の階層へ)")
                temp_dir=$(realpath "$temp_dir/..") ;;
            "EXIT     終了")
                echo "__EXIT__"; return ;;
            "")
                echo "$current_dir"; return ;;
            *)
                temp_dir=$(realpath "$temp_dir/$CHOICE") ;;
        esac
    done
}

# 保存済みファイルの音量を正規化して上書きする。
# 処理は手元のファイルの加工（LOCAL）と共通（形式・サンプルレートは元のまま、映像はそのまま）
normalize_file() {
    convert_local_file "$1" "$1" same "" "" "$LOUDNORM_FILTER"
}

# yt-dlp を更新するコマンド。
# 「yt-dlp -U」で更新できるのは配布バイナリだけなので、入れ方に合わせて案内する。
#   pacman で入れた → sudo pacman -Syu yt-dlp
#   pipx で入れた   → pipx upgrade yt-dlp
#   pip で入れた    → python3 -m pip install -U "yt-dlp[default]"
#                     （[default] で YouTube 用の yt-dlp-ejs も一緒に更新される）
#   それ以外（配布バイナリ）→ yt-dlp -U
# pip / pipx で入れたものは Python の起動スクリプトなので、1行目で見分ける。
ytdlp_update_cmd() {
    local bin real first=""
    bin=$(command -v yt-dlp)
    if [ -n "$bin" ] && command -v pacman &>/dev/null && pacman -Qqo "$bin" &>/dev/null; then
        echo "sudo pacman -Syu yt-dlp"
        return
    fi
    real=$(realpath "$bin" 2>/dev/null || echo "$bin")
    [ -f "$real" ] && IFS= read -r first < "$real" 2>/dev/null
    if [[ "$real" == */pipx/* ]]; then
        echo "pipx upgrade yt-dlp"
    elif [[ "$first" == "#!"*python* ]]; then
        echo "python3 -m pip install -U \"yt-dlp[default]\""
    else
        echo "yt-dlp -U"
    fi
}

# mpv の終了コードを見て、失敗していればログからエラーを表示する。
# 0 = 普通に終了（Q / ウィンドウを閉じる）、4 = Ctrl+C など。それ以外は再生に失敗している
_report_play_result() {
    local rc="$1" hint="$2"
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
        show_status "$C_ERR" "再生できませんでした"
        grep -iE "error|failed|unable" "$TEMP_PLAYLOG" | tail -n 3 | sed 's/^/  /'
        [ -n "$hint" ] && echo "$hint"
        wait_key
    fi
}

# mpv が無ければ案内して 1 を返す
_need_mpv() {
    command -v mpv &>/dev/null && return 0
    show_status "$C_ERR" "再生には mpv が必要です。パッケージマネージャでインストールしてください。"
    wait_key
    return 1
}

# yt-dlp で取得しながら mpv でストリーミング再生する。
# $2 = video: 動画で再生 / audio: 音声のみで再生（通信量が少ない）
# $3 = ウィンドウに表示するタイトル（省略時は URL）
play_stream() {
    local url="$1" mode="$2" title="${3:-$1}"
    local format="$STREAM_FORMAT"
    [ "$mode" == "audio" ] && format="$LISTEN_FORMAT"

    _need_mpv || return

    show_status "$C_MAIN" "再生中... （Q キーで終了）"

    # 動画の取得は yt-dlp に任せ、mpv には標準入力で流し込んで再生だけさせる。
    # （mpv に URL を渡して mpv 側で取得させると、YouTube の待ち時間の指定や
    #   取得時の IP との一致を満たせず、403 Forbidden で再生できないことがあるため）
    # mkv で結合して流す（mp4 は途中から読めないのでパイプでは再生できない）
    : > "$TEMP_PLAYLOG"
    yt-dlp -q --no-warnings --no-playlist --socket-timeout 10 \
        -f "$format" --merge-output-format mkv \
        -o - "$url" 2>> "$TEMP_PLAYLOG" \
    | mpv \
        --geometry=50% \
        --force-window \
        --cache=yes --demuxer-max-bytes=500MiB --demuxer-max-back-bytes=150MiB \
        --title="$title" \
        - >> "$TEMP_PLAYLOG" 2>&1
    # mpv の終了コードで判定する
    # （Q で mpv を閉じると yt-dlp は送り先がなくなって異常終了するが、これは正常）
    local rc=${PIPESTATUS[1]}

    # 「再生中...」の行を消す（消さないと、再生するたびに画面に積み重なる）
    # \033[1A = 1行上へ、\r = 行頭へ、\033[2K = その行を消去
    printf '\033[1A\r\033[2K'

    # yt-dlp が取得に失敗した場合も、mpv は何も受け取れずに失敗で終わる
    _report_play_result "$rc" "URL を確認してください。$(ytdlp_update_cmd) で yt-dlp を更新すると直ることがあります。$(js_runtime_hint)"
}

# 手元のファイルを mpv で再生する（複数なら続けて再生）
play_local() {
    _need_mpv || return
    show_status "$C_MAIN" "再生中... （Q キーで終了、> / < で次 / 前のファイル）"
    mpv --geometry=50% --force-window --keep-open=no "$@" > "$TEMP_PLAYLOG" 2>&1
    local rc=$?
    printf '\033[1A\r\033[2K'
    _report_play_result "$rc" ""
}

# ライブ配信中・配信開始前の動画は保存しない。
#   $1 = URL
#   $2 = 検索結果から分かっている配信の状態（is_live / is_upcoming / not_live など。不明なら空）
# 保存してよければ 0、ライブ配信なので保存しないなら 1 を返す。
# （配信中の動画をダウンロードすると、配信が終わるまで録画し続けて終わらないため）
check_not_live() {
    local url="$1" status="$2"

    # 検索結果で「配信ではない」と分かっていれば、確認のための通信はしない
    case "$status" in
        not_live|was_live|post_live) return 0 ;;
    esac

    # URL 指定のときなど、状態が分からなければ yt-dlp で確認する
    # （--ignore-no-formats-error: 配信開始前の動画でもエラーで止まらず状態を返させる）
    if [ "$status" != "is_live" ] && [ "$status" != "is_upcoming" ]; then
        show_status "$C_MAIN" "[ ライブ配信かどうか確認中... ]"
        status=$(yt-dlp --no-playlist --playlist-items 1 --skip-download --ignore-no-formats-error \
            --no-warnings --print "%(live_status|)s" "$url" 2>/dev/null | tail -n 1)
        printf '\033[1A\r\033[2K'   # 「確認中」の行を消す
    fi

    case "$status" in
        is_live)
            show_status "$C_ERR" "ライブ配信中の動画は保存できません"
            echo "  配信が終わってから保存してください。再生（STREAM）はできます。"
            wait_key
            return 1 ;;
        is_upcoming)
            show_status "$C_ERR" "配信開始前のライブ配信は保存できません"
            echo "  配信が終わってから保存してください。"
            wait_key
            return 1 ;;
    esac
    # 状態が確認できなかったときは通常どおり進める
    # （ダウンロード時の --match-filters でも配信中の動画は止まる）
    return 0
}

# 保存の設定（時間指定・音量正規化・画質 / 音声形式）をメニューで聞き、DL_* に入れる。
#   $1 = video / audio
#   $2 = yes なら時間指定も聞く（まとめて保存するときは聞かない）
# 戻る を選んだら 1 を返す。
ask_download_options() {
    local mode="$1" allow_range="$2"
    DL_SECTION_ARGS=()
    DL_FORMAT_ARGS=()
    DL_OUTPUT_TMPL="%(title).${TITLE_MAX_BYTES}B.%(ext)s"
    DL_DO_NORM=0
    DL_LABEL=""

    # --- 時間指定（1本だけ保存するとき） ---
    local RANGE_CHOICE="FULL     全体をダウンロード"
    [ "$allow_range" == "yes" ] && RANGE_CHOICE=$(fzf_menu "時間指定でダウンロードしますか？" \
        "FULL     全体をダウンロード" \
        "RANGE    範囲を指定する" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$RANGE_CHOICE" == "EXIT     終了" ] && do_exit
    if [ -z "$RANGE_CHOICE" ] || [ "$RANGE_CHOICE" == "BACK     戻る" ]; then return 1; fi

    if [ "$RANGE_CHOICE" == "RANGE    範囲を指定する" ]; then
        local RANGE_RESULT START_TIME END_TIME
        RANGE_RESULT=$(prompt_range_input)
        if [ -z "$RANGE_RESULT" ]; then return 1; fi

        START_TIME="${RANGE_RESULT%-*}"
        END_TIME="${RANGE_RESULT##*-}"
        DL_SECTION_ARGS=(--download-sections "*${START_TIME}-${END_TIME}")
        # --force-keyframes-at-cuts は映像のカットをきれいにするための再エンコード指定。
        # 音声抽出(-x)では不要で、付けるとファイルが生成されないことがあるため動画時のみ付与。
        [ "$mode" == "video" ] && DL_SECTION_ARGS+=(--force-keyframes-at-cuts)

        # 範囲指定時はファイル名に時間範囲を含める。
        # （全体版や他の切り抜きと名前が衝突して「ダウンロード済み」でスキップされるのを防ぐ）
        # ファイル名に使えない ":" は "-" に置換する。
        DL_OUTPUT_TMPL="%(title).${TITLE_MAX_BYTES_RANGE}B [${START_TIME//:/-}_${END_TIME//:/-}].%(ext)s"
    fi

    # --- 音量正規化 ---
    local NORM_CHOICE
    NORM_CHOICE=$(fzf_menu "音量を正規化しますか？（ラウドネスを統一）" \
        "NO       正規化しない" \
        "YES      正規化する" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$NORM_CHOICE" == "EXIT     終了" ] && do_exit
    if [ -z "$NORM_CHOICE" ] || [ "$NORM_CHOICE" == "BACK     戻る" ]; then return 1; fi
    [ "$NORM_CHOICE" == "YES      正規化する" ] && DL_DO_NORM=1

    # --- 画質 / 音声フォーマット ---
    if [ "$mode" == "video" ]; then
        local QUALITY SORT
        QUALITY=$(fzf_menu "画質を選択" \
            "1080p / MP4" \
            "720p / MP4" \
            "BEST     最高画質（4K等。再生できない機器あり）" \
            "BACK     戻る" \
            "EXIT     終了")
        [ "$QUALITY" == "EXIT     終了" ] && do_exit
        if [ -z "$QUALITY" ] || [ "$QUALITY" == "BACK     戻る" ]; then return 1; fi

        # 1080p/720p は H.264 + AAC を優先（どの機器でも再生しやすい MP4 にする）
        case "$QUALITY" in
            "1080p / MP4") SORT="res:1080,vcodec:h264,acodec:m4a" ;;
            "720p / MP4")  SORT="res:720,vcodec:h264,acodec:m4a" ;;
            *)             SORT="res,fps,vcodec,acodec" ;;
        esac
        DL_FORMAT_ARGS=(-S "$SORT" --merge-output-format mp4)
        DL_LABEL="[ ダウンロード中 ]"
    else
        local AUDIO_FMT FMT NOTE=""
        AUDIO_FMT=$(fzf_menu "音声フォーマットを選択" \
            "MP3      どの機器でも再生できる" \
            "M4A      YouTube の元データのまま（劣化なし）" \
            "BEST     YouTube の元データのまま（劣化なし・最高音質）" \
            "WAV      編集ソフト用（音質は元と同じ・サイズ約6倍）" \
            "FLAC     編集ソフト用（音質は元と同じ・サイズ約6倍）" \
            "BACK     戻る" \
            "EXIT     終了")
        [ "$AUDIO_FMT" == "EXIT     終了" ] && do_exit
        if [ -z "$AUDIO_FMT" ] || [ "$AUDIO_FMT" == "BACK     戻る" ]; then return 1; fi

        # 先頭の単語（MP3 / M4A / ...）で判定する
        case "${AUDIO_FMT%% *}" in
            MP3)  FMT="mp3"  ;;
            M4A)  FMT="m4a"  ;;
            BEST) FMT="best" ;;
            WAV)  FMT="wav"  ;;
            FLAC) FMT="flac" ;;
        esac
        DL_FORMAT_ARGS=(-x --audio-format "$FMT" --audio-quality 0)

        # M4A は YouTube にある AAC 音声をそのまま使う（Opus を取ってきて AAC に変換し直さない）
        [ "$FMT" == "m4a" ] && DL_FORMAT_ARGS+=(-S "acodec:m4a")

        # MP3 / WAV / FLAC は必ず変換が入るので、その変換の中で音量正規化も行う。
        # （変換 → 正規化 と2回に分けると、時間がかかり MP3 は劣化も重なるため）
        if [ "$DL_DO_NORM" -eq 1 ] && [[ "$FMT" =~ ^(mp3|wav|flac)$ ]]; then
            DL_FORMAT_ARGS+=(--postprocessor-args "ExtractAudio:-af $LOUDNORM_FILTER -ar 48000")
            DL_DO_NORM=0   # 変換時に済ませたので、後からの正規化は行わない
            NOTE="・音量正規化あり"
        fi
        DL_LABEL="[ 音声を抽出中: ${FMT}${NOTE} ]"
    fi
    return 0
}

# ask_download_options で決めた設定で1本ダウンロードし、結果を表示する。
#   $1 = URL / $2 = video / audio / $3 = 保存先フォルダ / $4 = yes なら最後にキー入力を待つ
# 保存できたら 0、失敗・スキップなら 1 を返す。
do_download() {
    local url="$1" mode="$2" output_dir="$3" wait="$4"

    # --- ダウンロード実行 ---
    echo ""
    show_status "$C_MAIN" "$DL_LABEL  完了まで画面をそのままにしてください"
    echo ""

    : > "$TEMP_PATHS"
    touch "$TEMP_MARKER"
    # --print-to-file で保存先のパスを記録（完了表示とスキップ判定に使う）
    # --no-mtime でファイルの更新日時をダウンロード時刻にする（スキップ判定に使う）
    # --no-playlist でプレイリスト付き URL（watch?v=…&list=…）でも選んだ1本だけを保存する
    # --playlist-items 1 は念のための歯止め。プレイリストやチャンネルの URL が
    #   すり抜けてきても、全動画ではなく先頭の1本だけで止める
    # --match-filters で、ライブ配信中・配信開始前の動画は保存しない（念のための二重チェック。
    #   「!=?」は、配信の状態が分からない動画（YouTube 以外など）は通す、という意味）
    #   【重要】正式名の --match-filters で書くこと。--match-filter は「途中まで打った
    #   名前を補う」仕組みでたまたま通っているだけで、似た名前のオプションが
    #   yt-dlp に増えると、その日からエラーで保存できなくなる。
    yt-dlp -P "$output_dir" "${DL_FORMAT_ARGS[@]}" \
        --no-playlist --playlist-items 1 \
        --match-filters "live_status!=?is_live & live_status!=?is_upcoming" \
        --embed-metadata --windows-filenames --no-mtime \
        --progress --newline \
        "${DL_SECTION_ARGS[@]}" \
        --print-to-file after_move:filepath "$TEMP_PATHS" \
        -o "$DL_OUTPUT_TMPL" "$url"
    local exit_code=$?
    echo ""

    if [ "$exit_code" -ne 0 ]; then
        show_status "$C_ERR" "ダウンロードに失敗しました"
        echo "上記のエラーメッセージを確認してください（$(ytdlp_update_cmd) で yt-dlp を更新すると直ることがあります）。"
        js_runtime_hint
        [ "$wait" == "yes" ] && wait_key
        return 1
    fi

    local saved
    saved=$(tail -n 1 "$TEMP_PATHS")
    if [ -z "$saved" ] || [ ! -f "$saved" ]; then
        show_status "$C_ERR" "保存されたファイルを確認できませんでした"
        echo "  保存先フォルダ: $output_dir"
        [ "$wait" == "yes" ] && wait_key
        return 1
    fi

    # 開始時刻より古いファイル = 今回は作られていない（同名ファイルがあってスキップされた）
    if [ ! "$saved" -nt "$TEMP_MARKER" ]; then
        show_status "$C_ERR" "同じ名前のファイルが既にあるため、ダウンロードをスキップしました"
        echo "  既存ファイル: $saved"
        echo "  作り直す場合は、既存ファイルを削除するか名前を変えてから実行してください。"
        [ "$wait" == "yes" ] && wait_key
        return 1
    fi

    if [ "$DL_DO_NORM" -eq 1 ]; then
        show_status "$C_MAIN" "[ 音量を正規化中 ]"
        if ! normalize_file "$saved"; then
            show_status "$C_ERR" "音量の正規化に失敗しました（ダウンロードしたファイルはそのまま残っています）"
            echo "  保存先: $saved"
            [ "$wait" == "yes" ] && wait_key
            return 1
        fi
    fi

    show_status "$C_OK" "[ 完了 ]"
    echo "  保存先: $saved"
    [ "$wait" == "yes" ] && wait_key
    return 0
}


run_download() {
    local url="$1"
    local mode="$2"
    local output_dir="$3"
    local live_status="$4"

    # --- ライブ配信の確認（時間指定などを選ばせる前に止める） ---
    check_not_live "$url" "$live_status" || return 0

    ask_download_options "$mode" yes || return 0
    do_download "$url" "$mode" "$output_dir" yes
    return 0
}

# 検索結果で複数選んだ動画をまとめて保存する。
# 引数: 検索結果の行（「表示用テキスト<TAB>動画ID<TAB>配信の状態」）を選んだ順に
batch_download() {
    local -a lines=("$@")
    local count=${#lines[@]} choice mode line title id status
    local i ok=0 fail=0 skip=0

    choice=$(fzf_menu "まとめて保存  |  ${count} 本の動画" \
        "VIDEO    まとめて動画保存" \
        "AUDIO    まとめて音声保存" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$choice" == "EXIT     終了" ] && do_exit
    if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then return 0; fi
    mode="video"
    [ "${choice%% *}" == "AUDIO" ] && mode="audio"

    # 設定は1回だけ聞いて、全部の動画に使う（時間指定は動画ごとに違うので聞かない）
    ask_download_options "$mode" no || return 0

    for i in "${!lines[@]}"; do
        line="${lines[$i]}"
        IFS=$'\t' read -r title id status <<< "$line"
        echo ""
        show_status "$C_MAIN" "[ $((i + 1))/${count} ] ${title}"
        if [ "$status" == "is_live" ] || [ "$status" == "is_upcoming" ]; then
            show_status "$C_ERR" "ライブ配信中・配信開始前の動画のため、保存しません"
            skip=$((skip + 1))
            continue
        fi
        if do_download "https://www.youtube.com/watch?v=$id" "$mode" "$TARGET_DIR" no; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    echo ""
    show_status "$C_OK" "[ まとめて保存 終了 ]  保存: ${ok} 本 / うまくいかなかった: ${fail} 本 / 対象外: ${skip} 本"
    echo "  保存先: $TARGET_DIR"
    [ "$fail" -gt 0 ] && echo "  うまくいかなかった動画は、上のメッセージを確認してください（同じ名前のファイルがある場合も含みます）。"
    wait_key
}

show_action_menu() {
    local url="$1"
    local target_dir="$2"
    local title="$3"
    local live_status="$4"   # 検索結果から分かっている配信の状態（URL 指定なら空）

    while true; do
        local ACTION
        ACTION=$(fzf_menu "操作を選択  |  $title" \
            "STREAM   ストリーミング再生" \
            "LISTEN   音声のみ再生（通信量が少ない）" \
            "VIDEO    動画保存" \
            "AUDIO    音声保存" \
            "URL      URLを確認 / コピー" \
            "BACK     戻る" \
            "EXIT     終了")

        [ "$ACTION" == "EXIT     終了" ] && do_exit
        if [ -z "$ACTION" ] || [ "$ACTION" == "BACK     戻る" ]; then return 0; fi

        case "$ACTION" in
            "STREAM   ストリーミング再生")
                play_stream "$url" video "$title" ;;
            "LISTEN   音声のみ再生（通信量が少ない）")
                play_stream "$url" audio "$title" ;;
            "VIDEO    動画保存")
                run_download "$url" "video" "$target_dir" "$live_status" ;;
            "AUDIO    音声保存")
                run_download "$url" "audio" "$target_dir" "$live_status" ;;
            "URL      URLを確認 / コピー")
                echo ""
                show_status "$C_MAIN" "この動画の URL:"
                echo "  $url"
                if copy_to_clipboard "$url"; then
                    show_status "$C_OK" "クリップボードにコピーしました"
                else
                    show_status "$C_ERR" "クリップボードツールが見つかりません（上の URL を手動でコピーしてください）"
                    echo "  ヒント: xclip / xsel / wl-clipboard のいずれかを入れると自動コピーできます"
                fi
                wait_key
                ;;
        esac
    done
}

# ============================================================
# 手元のファイル（LOCAL）: 時間指定・音量・形式変換・音楽CD
# ============================================================

# 貼り付け・ドラッグ＆ドロップされたパスを整える。
# 'パス' / "パス" の引用符、file:// で始まる形式、~ 、\ でエスケープされた空白に対応する。
_clean_path() {
    local p="$1"
    p="${p#"${p%%[![:space:]]*}"}"   # 先頭の空白を除く
    p="${p%"${p##*[![:space:]]}"}"   # 末尾の空白を除く
    if [[ "$p" == \'*\' || "$p" == \"*\" ]]; then
        p="${p:1:${#p}-2}"
    fi
    if [[ "$p" == file://* ]]; then
        p="${p#file://}"
        p=$(printf '%b' "${p//%/\\x}")   # %20 などの URL エンコードを元に戻す
    fi
    # shellcheck disable=SC2088  # 入力された文字の「~」をそのまま比べている
    [[ "$p" == "~" || "$p" == "~/"* ]] && p="${HOME}${p:1}"
    p="${p//\\ / }"
    echo "$p"
}

# 音声が入っているか
_has_audio() {
    [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null)" ]
}

# 映像が入っているか（MP3 などのジャケット画像は映像として扱わない）
_has_video() {
    ffprobe -v error -select_streams v -show_entries stream_disposition=attached_pic \
        -of csv=p=0 "$1" 2>/dev/null | grep -qx 0
}

# 長さ（秒、整数）。分からなければ空
_duration() {
    local d
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null)
    [[ "$d" =~ ^[0-9]+ ]] && echo "${BASH_REMATCH[0]}"
}

# 秒を「時:分:秒」または「分:秒」で表す
_fmt_time() {
    local t="$1"
    if (( t >= 3600 )); then
        printf '%d:%02d:%02d' $((t / 3600)) $((t % 3600 / 60)) $((t % 60))
    else
        printf '%d:%02d' $((t / 60)) $((t % 60))
    fi
}

# 文字列を指定バイト数以内に切り詰める（日本語の文字の途中では切らない）
_trim_bytes() {
    local s="$1" max="$2"
    while (( $(printf '%s' "$s" | wc -c) > max )); do
        s="${s%?}"
    done
    echo "$s"
}

# 同じ名前のファイルがあれば「名前 (2).拡張子」のように番号を付けたパスを返す
_unique_path() {
    local dir="$1" base="$2" ext="$3" path n=2
    path="$dir/$base.$ext"
    while [ -e "$path" ]; do
        path="$dir/$base ($n).$ext"
        n=$((n + 1))
    done
    echo "$path"
}

# フォルダ内の音声・動画ファイルを一覧から選ぶ（Tab で複数選択）。
# 選んだファイルは配列 LOCAL_FILES に入る（選んだ順）。選ばなかったら 1 を返す。
# 一覧は新しいファイルが上。サブフォルダは 3 階層まで探す。
pick_from_folder() {
    local dir="$1" list selected line
    LOCAL_FILES=()

    list=$(find "$dir" -maxdepth 3 -type f -regextype posix-extended \
            -iregex ".*\.(${LOCAL_EXTS})" \
            ! -name '*.norm-tmp.*' ! -name '*.local-tmp.*' ! -path '*/.*' \
            -printf '%T@\t%P\n' 2>/dev/null | sort -rn | cut -f2-)
    if [ -z "$list" ]; then
        show_status "$C_ERR" "音声・動画ファイルが見つかりませんでした"
        echo "  フォルダ: $dir"
        wait_key
        return 1
    fi

    selected=$(printf '%s\n' "$list" | fzf "${FZF_OPTS[@]}" --multi \
        --header="ファイルを選択  |  $dir
Tab で複数選択（選んだ順が CD の曲順）、Enter で決定、ESC で戻る" \
        --header-first \
        --no-sort \
        --height=80%)
    [ -z "$selected" ] && return 1

    while IFS= read -r line; do
        [ -n "$line" ] && LOCAL_FILES+=("$dir/$line")
    done <<< "$selected"
    return 0
}

# 音量の上げ下げを dB で入力させる。例: 3（上げる） / -6（下げる）
# 空入力(ESC)なら空文字を返す。結果は標準出力で返すため、エラー表示は標準エラーに出す。
prompt_gain_input() {
    local input
    while true; do
        input=$(echo "" | fzf "${FZF_OPTS[@]}" \
            --header="音量の変化を dB で入力  例: 3（上げる） / -6（下げる）  ※ 6dB でおよそ2倍・半分の大きさ（ESCで戻る）" \
            --header-first --height=30% --print-query --no-sort --query="" | tail -1)

        # 全角の数字・記号を半角にそろえ、空白と「dB」を取り除く
        input=$(printf '%s' "$input" | sed 'y/０１２３４５６７８９．＋－ー/0123456789.+--/')
        input="${input//[[:space:]]/}"
        input="${input%[dD][bB]}"

        if [ -z "$input" ]; then
            echo ""
            return
        fi

        if ! [[ "$input" =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]]; then
            show_status "$C_ERR" "数字で入力してください　例: 3 / -6 / 1.5" >&2
            sleep 1.5
            continue
        fi
        if awk -v g="$input" 'BEGIN { exit !(g == 0 || g > 30 || g < -30) }'; then
            show_status "$C_ERR" "-30 から 30 の範囲で、0 以外の値を入力してください" >&2
            sleep 1.5
            continue
        fi

        echo "${input#+}"
        return
    done
}

# 1つのファイルを ffmpeg で加工して保存する。
#   $1 入力 / $2 出力
#   $3 出力の種類（same = 元の形式のまま / mp3 / m4a / wav / flac / cdwav = 音楽CD用 WAV）
#   $4 開始秒（空なら先頭から） / $5 長さ秒（空なら最後まで） / $6 音声フィルタ（空ならなし）
convert_local_file() {
    local in="$1" out="$2" kind="$3" start="$4" len="$5" af="$6"
    local ext="${out##*.}"
    local tmp="${out%.*}.local-tmp.${ext}"
    local in_args=() map_args=() codec_args=() other_args=() rate

    [ -n "$start" ] && in_args=(-ss "$start")
    [ -n "$len" ] && other_args+=(-t "$len")

    # 元のサンプルレートを保つ（loudnorm は既定で 192kHz にしてしまうため指定し直す）
    rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$in" 2>/dev/null)
    [[ "$rate" =~ ^[0-9]+$ ]] || rate=48000

    case "$kind" in
        mp3)   map_args=(-map 0:a:0); codec_args=(-c:a libmp3lame -q:a 0) ;;
        m4a)   map_args=(-map 0:a:0); codec_args=(-c:a aac -b:a 256k) ;;
        wav)   map_args=(-map 0:a:0); codec_args=(-c:a pcm_s16le) ;;
        flac)  map_args=(-map 0:a:0); codec_args=(-c:a flac) ;;
        cdwav)
            # CD の規格（44.1kHz / 16bit / ステレオ）。4 秒未満の曲は CD に書けないので無音を足して 4 秒にする
            map_args=(-map 0:a:0); codec_args=(-c:a pcm_s16le -ac 2); rate=44100
            af="${af:+$af,}apad=whole_dur=4" ;;
        same)
            # 音声は拡張子に合った形式で作り直す
            case "${ext,,}" in
                mp3|avi)                codec_args=(-c:a libmp3lame -q:a 0) ;;
                m4a|aac|mp4|m4v|mov|mkv) codec_args=(-c:a aac -b:a 192k) ;;
                opus|ogg|oga|webm)      codec_args=(-c:a libopus -b:a 160k); rate=48000 ;;  # Opus は 48kHz 固定
                flac)                   codec_args=(-c:a flac) ;;
                wav)                    codec_args=(-c:a pcm_s16le) ;;
                wma)                    codec_args=(-c:a wmav2 -b:a 192k) ;;
            esac
            if _has_video "$in"; then
                map_args=(-map 0:v:0 -map 0:a:0)
                if [ -n "$start$len" ]; then
                    # 切り出すときは、位置を正確にするため映像も作り直す
                    if [ "${ext,,}" == "webm" ]; then
                        codec_args+=(-c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -cpu-used 4)
                    else
                        codec_args+=(-c:v libx264 -crf 18 -preset veryfast)
                    fi
                else
                    codec_args+=(-c:v copy)   # 音量だけ変えるときは映像はそのまま
                fi
                [[ "${ext,,}" =~ ^(mp4|m4v|mov)$ ]] && codec_args+=(-movflags +faststart)
            else
                map_args=(-map 0:a:0)
            fi
            ;;
    esac

    [ -n "$af" ] && other_args+=(-af "$af")

    if ffmpeg -nostdin -hide_banner -loglevel error -stats -y \
            "${in_args[@]}" -i "$in" -map_metadata 0 \
            "${map_args[@]}" "${other_args[@]}" "${codec_args[@]}" -ar "$rate" "$tmp"; then
        mv -f "$tmp" "$out"
    else
        rm -f "$tmp"
        return 1
    fi
}

# 音楽CDの書き込みソフトを探す。
# cdrdao を優先する（日本語の曲名を CD-Text として書き込めるため）。無ければ cdrecord / wodim
_find_cd_writer() {
    local cmd
    for cmd in cdrdao cdrecord wodim; do
        if command -v "$cmd" &>/dev/null; then
            echo "$cmd"
            return
        fi
    done
}

# CD-Text に書く文字列を整える。
# CD-Text の日本語は Shift_JIS（CP932）なので、そこで表せない文字（絵文字など）は除き、
# TOC ファイルの書式を壊す " と \ は置き換え、長すぎるものは切り詰める
_cdtext_str() {
    local s="$1"
    s=$(printf '%s' "$s" | iconv -c -f UTF-8 -t CP932 2>/dev/null | iconv -f CP932 -t UTF-8 2>/dev/null)
    s="${s//\"/\'}"
    s="${s//\\/／}"
    s="${s//[$'\t\r\n']/ }"
    printf '%s' "${s:0:60}"
}

# ファイルのタグ（title / artist など）を読む。無ければ空
_tag() {
    ffprobe -v error -show_entries "format_tags=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1
}

# cdrdao 用の TOC ファイル（曲順・曲名などを書いた設計図）を作る。
#   $1 TOC の保存先 / $2 CD のタイトル（空なら「CD 日付」） / $3 yes なら CD-Text を書く
#   続く引数: 「WAVのパス<TAB>曲名<TAB>アーティスト」を曲順に
#
# CD-Text では、タイトル（TITLE）とアーティスト（PERFORMER）を CD 全体とすべての曲に
# 書かないと、書き込み時にエラーになる（空の文字も「書いていない」扱いになる）。
# そのため、空のものは次のように埋める。
#   CD のタイトル: 「CD 日付」
#   曲名: ファイル名（タグもファイル名も使えなければ「トラック 番号」）
#   アーティスト: タグの値。無い曲は、ほかの曲のアーティストが1人ならその人、それ以外は「不明」
#   CD 全体のアーティスト: 全曲が同じ人ならその人、複数なら「V.A.」（いろいろなアーティスト）
_write_toc() {
    local toc="$1" album="$2" use_text="$3"; shift 3
    local entry wav title artist n=0 a
    local disc_artist="" track_default="不明"
    local -a names=()

    album=$(_cdtext_str "$album")
    [ -z "$album" ] && album="CD $(date +%Y-%m-%d)"

    # 曲に付いているアーティストの種類を数える
    for entry in "$@"; do
        IFS=$'\t' read -r wav title artist <<< "$entry"
        a=$(_cdtext_str "$artist")
        [ -z "$a" ] && continue
        local known=0 k
        for k in "${names[@]}"; do [ "$k" == "$a" ] && known=1; done
        [ "$known" -eq 0 ] && names+=("$a")
    done
    if [ ${#names[@]} -eq 1 ]; then
        disc_artist="${names[0]}"
        track_default="${names[0]}"
    elif [ ${#names[@]} -gt 1 ]; then
        disc_artist="V.A."
    else
        disc_artist="不明"
    fi

    {
        echo "CD_DA"
        if [ "$use_text" == "yes" ]; then
            # 105 = 日本語（CD-Text の言語コード）。ENCODING_MS_JIS で Shift_JIS として書き込む
            printf 'CD_TEXT {\n  LANGUAGE_MAP {\n    0 : 105\n  }\n  LANGUAGE 0 {\n'
            printf '    ENCODING_MS_JIS\n    TITLE "%s"\n    PERFORMER "%s"\n  }\n}\n' "$album" "$disc_artist"
        fi
        for entry in "$@"; do
            n=$((n + 1))
            IFS=$'\t' read -r wav title artist <<< "$entry"
            printf '\nTRACK AUDIO\n'
            if [ "$use_text" == "yes" ]; then
                title=$(_cdtext_str "$title")
                [ -z "$title" ] && title="トラック $n"
                artist=$(_cdtext_str "$artist")
                [ -z "$artist" ] && artist="$track_default"
                printf 'CD_TEXT {\n  LANGUAGE 0 {\n    TITLE "%s"\n    PERFORMER "%s"\n  }\n}\n' "$title" "$artist"
            fi
            printf 'FILE "%s" 0\n' "$wav"
        done
    } > "$toc"
}

# 選んだファイルを音楽CDに書き込む。
#   $1 開始秒 / $2 長さ秒 / $3 音声フィルタ（いずれも空なら指定なし。時間指定は1ファイルのときだけ）
burn_audio_cd() {
    local start="$1" len="$2" af="$3"
    local writer dev total=0 d i f choice album="" out rc
    local -a devs durs titles artists

    writer=$(_find_cd_writer)
    if [ -z "$writer" ]; then
        show_status "$C_ERR" "CD の書き込みには cdrdao（または cdrtools）が必要です"
        echo "  インストール: sudo pacman -S cdrdao"
        echo "  （cdrdao なら、曲名入りの CD を作れます）"
        wait_key
        return 0
    fi

    # --- CD ドライブを選ぶ ---
    for d in /dev/sr[0-9]*; do
        [ -e "$d" ] && devs+=("$d")
    done
    if [ ${#devs[@]} -eq 0 ]; then
        show_status "$C_ERR" "CD ドライブが見つかりません（/dev/sr0 など）"
        echo "  ドライブがつながっているか確認してください。"
        wait_key
        return 0
    elif [ ${#devs[@]} -eq 1 ]; then
        dev="${devs[0]}"
    else
        dev=$(fzf_menu "書き込む CD ドライブを選択" "${devs[@]}")
        [ -z "$dev" ] && return 0
    fi

    # --- 合計時間と曲名を確認する ---
    for f in "${LOCAL_FILES[@]}"; do
        d="$len"
        [ -z "$d" ] && d=$(_duration "$f")
        if [ -z "$d" ]; then
            show_status "$C_ERR" "長さを確認できないファイルがあります"
            echo "  $f"
            wait_key
            return 0
        fi
        (( d < 4 )) && d=4   # CD の規格で、4 秒未満の曲は無音を足して 4 秒にする
        durs+=("$d")
        total=$((total + d))
        # 曲名はファイルのタグ（無ければファイル名）を使う
        out=$(_tag "$f" title)
        [ -z "$out" ] && out="$(basename "${f%.*}")"
        titles+=("$out")
        artists+=("$(_tag "$f" artist)")
    done
    # 曲間の 2 秒（1 曲目の前の空白）の分も見ておく
    if (( total + 2 > CD_MAX_SECONDS )); then
        show_status "$C_ERR" "合計 $(_fmt_time "$total") で、CD に入る時間（$(_fmt_time "$CD_MAX_SECONDS")）を超えています"
        echo "  曲を減らすか、時間指定で短くしてください。"
        wait_key
        return 0
    fi

    # --- 曲順と合計時間を見せて確認する ---
    clear
    show_status "$C_MAIN" "[ 音楽CDに書き込む曲 ]  ドライブ: $dev"
    for i in "${!LOCAL_FILES[@]}"; do
        printf '  %2d. %s  (%s)\n' $((i + 1)) "${titles[$i]}" "$(_fmt_time "${durs[$i]}")"
    done
    echo "  合計: $(_fmt_time "$total")（${#LOCAL_FILES[@]} 曲）"
    (( total > 4440 )) && echo "  ※ 74 分を超えているため、80 分の CD-R が必要です"
    if [ "$writer" == "cdrdao" ]; then
        echo "  曲名（上の名前）も CD に書き込みます（CD-Text。対応する機器で表示されます）"
    else
        echo "  ※ 曲名の書き込み（CD-Text）には cdrdao が必要です（sudo pacman -S cdrdao）"
    fi
    echo ""

    choice=$(fzf_menu "書き込みますか？（空の CD-R を入れてから選んでください）" \
        "BURN     書き込む" \
        "TEST     試し書き（実際には書き込まずに動作だけ確認）" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$choice" == "EXIT     終了" ] && do_exit
    if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then clear; return 0; fi

    # --- CD のタイトル（cdrdao のときだけ） ---
    if [ "$writer" == "cdrdao" ]; then
        out=$(echo "" | fzf "${FZF_OPTS[@]}" \
            --header="CD のタイトル（アルバム名）を入力して Enter。空のまま Enter なら「CD $(date +%Y-%m-%d)」（ESC で戻る）" \
            --header-first --height=30% --print-query --no-sort --query="")
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then clear; return 0; fi   # ESC
        album=$(head -n 1 <<< "$out")
    else
        # cdrecord / wodim は書き込む前にディスクの有無を確かめられる
        if ! "$writer" dev="$dev" -atip &>/dev/null; then
            show_status "$C_ERR" "ディスクが入っていないか、読み取れません"
            echo "  空の CD-R を入れて、数秒待ってからやり直してください。"
            wait_key
            return 0
        fi
    fi

    # --- CD 用の WAV（44.1kHz / 16bit / ステレオ）を一時フォルダに作る ---
    # /tmp はメモリ上にあることが多く、CD 1枚分（最大 800MB 程度）を置くと重くなるため、
    # ホームのキャッシュフォルダを使う
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
    mkdir -p "$cache_dir"
    TEMP_CD_DIR=$(mktemp -d "$cache_dir/yt-fzf-cd.XXXXXX")
    local -a wavs entries
    echo ""
    for i in "${!LOCAL_FILES[@]}"; do
        f="${LOCAL_FILES[$i]}"
        show_status "$C_MAIN" "[ CD 用に変換中 $((i + 1))/${#LOCAL_FILES[@]} ] $(basename "$f")"
        wavs+=("$TEMP_CD_DIR/$(printf '%02d' $((i + 1))).wav")
        entries+=("${wavs[$i]}"$'\t'"${titles[$i]}"$'\t'"${artists[$i]}")
        if ! convert_local_file "$f" "${wavs[$i]}" cdwav "$start" "$len" "$af"; then
            show_status "$C_ERR" "変換に失敗しました: $(basename "$f")"
            rm -rf "$TEMP_CD_DIR"; TEMP_CD_DIR=""
            wait_key
            return 0
        fi
    done

    local is_test=0
    [ "$choice" == "TEST     試し書き（実際には書き込まずに動作だけ確認）" ] && is_test=1
    if [ "$is_test" -eq 1 ]; then
        show_status "$C_MAIN" "[ 試し書き中 ]  実際には書き込みません"
    else
        show_status "$C_MAIN" "[ 書き込み中 ]  終わるまでディスクを取り出さないでください"
    fi
    echo ""

    # --- 書き込む ---
    if [ "$writer" == "cdrdao" ]; then
        local toc="$TEMP_CD_DIR/disc.toc" text_note=""
        _write_toc "$toc" "$album" yes "${entries[@]}"
        # 古い cdrdao（1.2.5 より前）は日本語の CD-Text を書けないので、曲名なしで書き込む
        # （show-toc は書式を確かめるだけで、CD-Text の項目がそろっているかまでは確かめない）
        if ! cdrdao show-toc "$toc" &>/dev/null; then
            _write_toc "$toc" "" no "${entries[@]}"
            text_note="（cdrdao が古いため、曲名なしで書き込みました）"
            show_status "$C_ERR" "cdrdao が古いため、曲名（CD-Text）なしで書き込みます"
        fi
        # -n: 書き込み前の 10 秒の待ち時間をなくす
        # 1 曲目の前の 2 秒以外は曲間に無音を入れない（ファイルの長さのまま、つなげて書き込む）
        if [ "$is_test" -eq 1 ]; then
            cdrdao simulate --device "$dev" -n "$toc"
        else
            cdrdao write --device "$dev" -n --eject "$toc"
        fi
        rc=$?
    else
        # -dao: 曲間に余計な無音を入れずに一度に書き込む
        # -pad: 曲の長さを CD の区切り（1/75 秒）に合わせて無音で埋める
        local -a burn_args=(-v dev="$dev" -dao -audio -pad)
        if [ "$is_test" -eq 1 ]; then
            burn_args=(-dummy "${burn_args[@]}")
        else
            burn_args=(-eject "${burn_args[@]}")
        fi
        "$writer" "${burn_args[@]}" "${wavs[@]}"
        rc=$?
    fi
    rm -rf "$TEMP_CD_DIR"; TEMP_CD_DIR=""
    echo ""

    if [ "$rc" -ne 0 ]; then
        show_status "$C_ERR" "書き込みに失敗しました"
        echo "  上のメッセージを確認してください。"
        echo "  ・ディスクが入っているか、空の CD-R か確認してください（使用済みの CD-R には書き込めません）"
        echo "  ・CD-RW は消去してから書き込んでください"
    elif [ "$is_test" -eq 0 ]; then
        show_status "$C_OK" "[ 完了 ]  音楽CDに書き込みました（${#LOCAL_FILES[@]} 曲 / $(_fmt_time "$total")）${text_note:-}"
    else
        show_status "$C_OK" "[ 試し書き完了 ]  問題なく書き込めそうです。BURN で本番の書き込みをしてください"
    fi
    wait_key
}

# 選んだファイル（LOCAL_FILES）に、時間指定・音量・形式変換をまとめて行う
run_local_process() {
    local count=${#LOCAL_FILES[@]}
    local label start="" len="" range_tag="" af="" vol_tag="" kind out_ext
    local choice

    if [ "$count" -eq 1 ]; then
        label="$(basename "${LOCAL_FILES[0]}")"
    else
        label="${count} 個のファイル"
    fi

    # --- 時間指定（1ファイルのときだけ） ---
    if [ "$count" -eq 1 ]; then
        choice=$(fzf_menu "時間指定で切り出しますか？  |  $label" \
            "FULL     全体を使う" \
            "RANGE    範囲を指定する" \
            "BACK     戻る" \
            "EXIT     終了")
        [ "$choice" == "EXIT     終了" ] && do_exit
        if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then return 0; fi

        if [ "$choice" == "RANGE    範囲を指定する" ]; then
            local range s e dur
            range=$(prompt_range_input)
            [ -z "$range" ] && return 0
            s="${range%-*}"; e="${range##*-}"
            start=$(_to_seconds "$s")
            len=$(( $(_to_seconds "$e") - start ))
            dur=$(_duration "${LOCAL_FILES[0]}")
            if [ -n "$dur" ] && (( start >= dur )); then
                show_status "$C_ERR" "開始時間がファイルの長さ（$(_fmt_time "$dur")）を超えています"
                wait_key
                return 0
            fi
            range_tag=" [${s//:/-}_${e//:/-}]"
        fi
    fi

    # --- 音量 ---
    choice=$(fzf_menu "音量を調整しますか？  |  $label" \
        "NO       変更しない" \
        "NORM     正規化する（ほかの曲と音量をそろえる）" \
        "GAIN     上げる / 下げる（dB で指定）" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$choice" == "EXIT     終了" ] && do_exit
    if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then return 0; fi
    case "${choice%% *}" in
        NORM)
            af="$LOUDNORM_FILTER"
            vol_tag=" [正規化]" ;;
        GAIN)
            local gain
            gain=$(prompt_gain_input)
            [ -z "$gain" ] && return 0
            af="volume=${gain}dB"
            # 上げるときは、音が割れないよう上限（-1dB）を超えた部分だけ抑える
            [[ "$gain" != -* ]] && af+=",alimiter=limit=0.891:level=false"
            [[ "$gain" == -* ]] && vol_tag=" [${gain}dB]" || vol_tag=" [+${gain}dB]"
            ;;
    esac

    # --- 保存の形式 ---
    choice=$(fzf_menu "保存の形式を選択  |  $label" \
        "SAME     元の形式のまま" \
        "MP3      どの機器でも再生できる" \
        "M4A      AAC（スマホ向け）" \
        "WAV      編集ソフト用（劣化なし・サイズ大）" \
        "FLAC     編集ソフト用（劣化なし・WAV より小さい）" \
        "CDWAV    音楽CD用の WAV（別のソフトで CD に焼く用）" \
        "CDBURN   音楽CDに書き込む" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$choice" == "EXIT     終了" ] && do_exit
    if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then return 0; fi
    kind="${choice%% *}"; kind="${kind,,}"

    if [ "$kind" == "cdburn" ]; then
        burn_audio_cd "$start" "$len" "$af"
        return 0
    fi

    # --- 保存先を決める ---
    # CD 用 WAV は、保存先フォルダに「CD_日時」のフォルダを作り、曲順の番号を付けて並べる。
    # それ以外は、元のファイルと同じフォルダに名前を変えて保存する（元のファイルは変更しない）。
    local cd_dir=""
    if [ "$kind" == "cdwav" ]; then
        cd_dir="$TARGET_DIR/CD_$(date +%Y%m%d-%H%M%S)"
        if ! mkdir -p "$cd_dir"; then
            show_status "$C_ERR" "フォルダを作れませんでした: $cd_dir"
            wait_key
            return 0
        fi
    fi

    local i f in_ext base dir out ok=0 skip=0 fail=0
    local -a done_list
    echo ""
    for i in "${!LOCAL_FILES[@]}"; do
        f="${LOCAL_FILES[$i]}"
        in_ext="${f##*.}"
        base="$(basename "${f%.*}")"

        case "$kind" in
            same)  out_ext="$in_ext" ;;
            cdwav) out_ext="wav" ;;
            *)     out_ext="$kind" ;;
        esac

        # 何も変わらない（同じ形式で、時間指定も音量の変更もない）ファイルは作らない
        if [ "$kind" != "cdwav" ] && [ "${out_ext,,}" == "${in_ext,,}" ] && [ -z "$range_tag$vol_tag" ]; then
            show_status "$C_ERR" "[ スキップ ] 変更する内容がありません: $(basename "$f")"
            skip=$((skip + 1))
            continue
        fi

        if [ "$kind" == "cdwav" ]; then
            out=$(_unique_path "$cd_dir" "$(printf '%02d' $((i + 1))) $(_trim_bytes "$base" 180)" wav)
        else
            dir="$(dirname "$f")"
            [ -w "$dir" ] || dir="$TARGET_DIR"   # 書き込めない場所なら保存先フォルダへ
            out=$(_unique_path "$dir" "$(_trim_bytes "$base" 180)${range_tag}${vol_tag}" "$out_ext")
        fi

        show_status "$C_MAIN" "[ 変換中 $((i + 1))/${count} ] $(basename "$f")"
        if convert_local_file "$f" "$out" "$kind" "$start" "$len" "$af"; then
            ok=$((ok + 1))
            done_list+=("$out")
        else
            show_status "$C_ERR" "[ 失敗 ] $(basename "$f")"
            fail=$((fail + 1))
        fi
    done
    echo ""

    if [ "$ok" -gt 0 ]; then
        show_status "$C_OK" "[ 完了 ] ${ok} 個のファイルを保存しました"
        if [ -n "$cd_dir" ]; then
            echo "  保存先: $cd_dir"
            echo "  （ファイル名の番号順に CD に焼いてください）"
        else
            printf '  %s\n' "${done_list[@]}"
        fi
    elif [ -n "$cd_dir" ]; then
        rmdir "$cd_dir" 2>/dev/null   # 1つもできなかったら空のフォルダは消す
    fi
    [ "$fail" -gt 0 ] && show_status "$C_ERR" "${fail} 個のファイルは変換に失敗しました（上のメッセージを確認してください）"
    [ "$skip" -gt 0 ] && echo "  ※ 時間指定・音量・形式のどれかを変えると、そのファイルも保存されます"

    # 保存できたファイルは、その場で再生して確認できるようにする
    if [ "$ok" -gt 0 ]; then
        echo ""
        choice=$(fzf_menu "保存したファイルを再生して確認できます" \
            "OK       メニューに戻る" \
            "PLAY     保存したファイルを再生")
        [ "$choice" == "PLAY     保存したファイルを再生" ] && play_local "${done_list[@]}"
        clear
    else
        wait_key
    fi
}

# 手元のファイルを選んで加工するメニュー
local_menu() {
    local choice input p f
    local -a usable

    while true; do
        choice=$(fzf_menu "手元のファイルを加工  |  ファイルの選び方" \
            "LIST     保存先フォルダから選ぶ" \
            "PATH     ファイル / フォルダの場所を入力" \
            "BACK     戻る" \
            "EXIT     終了")
        [ "$choice" == "EXIT     終了" ] && do_exit
        if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then return 0; fi

        if [ "$choice" == "LIST     保存先フォルダから選ぶ" ]; then
            pick_from_folder "$TARGET_DIR" || continue
        else
            input=$(echo "" | fzf "${FZF_OPTS[@]}" \
                --header="ファイルまたはフォルダの場所を入力して Enter（ドラッグ＆ドロップ可。ESC で戻る）" \
                --header-first --height=30% --print-query --no-sort --query="" | tail -1)
            p=$(_clean_path "$input")
            [ -z "$p" ] && continue
            if [ -d "$p" ]; then
                pick_from_folder "$(realpath "$p")" || continue
            elif [ -f "$p" ]; then
                LOCAL_FILES=("$(realpath "$p")")
            else
                show_status "$C_ERR" "ファイルまたはフォルダが見つかりません"
                echo "  $p"
                wait_key
                continue
            fi
        fi

        # 音声の入っていないファイル（画像など）は除く
        usable=()
        for f in "${LOCAL_FILES[@]}"; do
            if _has_audio "$f"; then
                usable+=("$f")
            else
                show_status "$C_ERR" "音声が入っていないため除きます: $(basename "$f")"
            fi
        done
        if [ ${#usable[@]} -eq 0 ]; then
            wait_key
            continue
        fi
        [ ${#usable[@]} -ne ${#LOCAL_FILES[@]} ] && sleep 1.5
        LOCAL_FILES=("${usable[@]}")

        local label
        label="$(basename "${LOCAL_FILES[0]}")"
        [ ${#LOCAL_FILES[@]} -gt 1 ] && label="${#LOCAL_FILES[@]} 個のファイル"
        while true; do
            choice=$(fzf_menu "操作を選択  |  $label" \
                "EDIT     加工する（時間指定・音量・形式・CD）" \
                "PLAY     再生する" \
                "BACK     戻る" \
                "EXIT     終了")
            [ "$choice" == "EXIT     終了" ] && do_exit
            if [ -z "$choice" ] || [ "$choice" == "BACK     戻る" ]; then break; fi
            if [ "$choice" == "PLAY     再生する" ]; then
                play_local "${LOCAL_FILES[@]}"
                continue
            fi
            run_local_process
            break
        done
    done
}

show_help() {
    local name
    name=$(basename "$0")
    cat <<EOF
yt-fzf v${VERSION}

使い方: ${name} [オプション]

fzf のメニューで YouTube 動画を検索・再生・保存するツールです。
手元の音声・動画ファイルの加工（時間指定・音量・音楽CD）もできます。
オプションなしで起動するとメニューが開きます。

オプション:
  -h, --help       このヘルプを表示して終了
  -v, --version    バージョンと本体の場所を表示して終了

メインメニュー:
  SEARCH   キーワードで検索（上位 ${SEARCH_COUNT} 件。Tab で複数選ぶと、まとめて保存）
  URL      URL を直接入力
  LOCAL    手元のファイルを加工（下記）
  CONFIG   保存先フォルダを変更（次回以降も記憶）
  EXIT     終了

動画を選んだあとの操作:
  STREAM   ストリーミング再生（Q で終了）
  LISTEN   音声のみ再生（通信量が少ない）
  VIDEO    動画保存（1080p / 720p / 最高画質、MP4）
  AUDIO    音声保存（MP3 / M4A / BEST / WAV / FLAC）
           M4A・BEST は YouTube の音声をそのまま保存（劣化なし）
  URL      動画の URL を表示してクリップボードにコピー
           ※ ライブ配信中・配信開始前の動画は保存できません（再生はできます）
           ※ 検索結果では [LIVE] / [配信予定] の印が付きます

保存時の設定:
  時間指定  「開始-終了」で範囲を切り出し（例: 0:00-1:00、1:20:00-1:25:30）
            ファイル名に範囲が付きます（例: タイトル [0-00_1-00].mp3）
  音量正規化  音量をそろえます（形式・サンプルレートは元のまま）

手元のファイルの加工（LOCAL）:
  選び方    保存先フォルダの一覧から選ぶ（Tab で複数選択）／場所を入力（ドラッグ＆ドロップ可）
  操作      EDIT 加工する / PLAY 再生する（加工したファイルも、保存後にその場で再生できます）
  時間指定  「開始-終了」で切り出し（1ファイルを選んだときのみ）
  音量      正規化（音量をそろえる）／dB を指定して上げる・下げる
  形式      元のまま / MP3 / M4A / WAV / FLAC
            CDWAV  音楽CD用の WAV（保存先に CD_日時 フォルダを作り、曲順の番号付きで保存）
            CDBURN 音楽CDに書き込む（選んだ順が曲順。cdrdao なら曲名も書き込む）
  元のファイルは変更せず、同じフォルダに名前を変えて保存します

操作:
  ↑↓ / マウス で選択、Enter で決定、ESC または BACK で戻る

必要なもの:
  fzf, yt-dlp, ffmpeg（ffprobe）  必須
  deno                            YouTube の暗号の処理（無いと画質が減る。Arch では yt-dlp と一緒に入る）
  mpv                             再生するときのみ
  wl-copy / xclip / xsel          URL の自動コピーを使うときのみ
  cdrdao（または cdrecord）       音楽CDに書き込むときのみ（cdrdao なら曲名入り）

保存先の記録: ${LAST_DIR_FILE}
現在の保存先: ${TARGET_DIR}

設定ファイル: ${CONFIG_FILE}
  ストリーミング再生の画質・検索結果の件数などを変えられます（中に説明があります）

うまく動かないときは、まず yt-dlp を更新してください: $(ytdlp_update_cmd)
EOF
}

# --- メイン処理 ---

# テストから関数だけを読み込めるよう、メイン処理は関数にまとめ、
# 直接実行されたときだけ呼ぶ（source yt-fzf.sh では何も始まらない）。
main() {

    # 起動オプション（ツールが未インストールでもヘルプは見られるよう、依存チェックより前に処理）
    case "$1" in
        "") ;;
        -h|--help)
            show_help
            exit 0 ;;
        -v|--version)
            # 本体の場所も出す（古いものが別の場所にあって優先されていないか確認できるように）
            echo "yt-fzf v${VERSION}"
            echo "本体の場所: $(realpath "$0" 2>/dev/null || echo "$0")"
            exit 0 ;;
        *)
            echo "不明なオプション: $1" >&2
            echo "使い方は $(basename "$0") -h で確認できます。" >&2
            exit 1 ;;
    esac

    # mpv は再生するときだけ必要なので、ここではチェックしない
    check_dependency fzf
    check_dependency yt-dlp
    check_dependency ffmpeg
    check_dependency ffprobe
    notice_js_runtime

    while true; do
        MODE=$(fzf_menu "保存先: $(basename "$TARGET_DIR")" \
            "SEARCH   キーワードで検索" \
            "URL      URLを入力" \
            "LOCAL    手元のファイルを加工（時間指定・音量・CD）" \
            "CONFIG   保存先を変更" \
            "EXIT     終了")

        [ -z "$MODE" ] || [ "$MODE" == "EXIT     終了" ] && do_exit

        if [ "$MODE" == "CONFIG   保存先を変更" ]; then
            NEW_DIR=$(select_directory "$TARGET_DIR")
            [ "$NEW_DIR" == "__EXIT__" ] && do_exit
            # 念のため、実在するフォルダのときだけ保存先を更新・記録する
            if [ -d "$NEW_DIR" ]; then
                TARGET_DIR="$NEW_DIR"
                echo "$TARGET_DIR" > "$LAST_DIR_FILE"
            fi
            continue
        fi

        if [ "$MODE" == "LOCAL    手元のファイルを加工（時間指定・音量・CD）" ]; then
            local_menu
            continue
        fi

        if [ "$MODE" == "URL      URLを入力" ]; then
            # fzf の入力モードで URL を受け取る
            URL=$(echo "" | fzf "${FZF_OPTS[@]}" \
                --header="URL を入力して Enter（ESC で戻る）" \
                --header-first \
                --height=30% \
                --print-query \
                --no-sort \
                --query="" | tail -1)
            URL="${URL//[[:space:]]/}"
            [ -z "$URL" ] && continue
            if is_collection_url "$URL"; then
                show_status "$C_ERR" "プレイリストやチャンネルの URL には対応していません"
                echo "  動画1本の URL（https://www.youtube.com/watch?v=… など）を入力してください。"
                echo "  プレイリストを再生中の URL（watch?v=…&list=…）なら、その動画1本だけを扱えます。"
                wait_key
                continue
            fi
            show_action_menu "$URL" "$TARGET_DIR" "URL 指定の動画"
            continue
        fi

        if [ "$MODE" == "SEARCH   キーワードで検索" ]; then
            QUERY=$(echo "" | fzf "${FZF_OPTS[@]}" \
                --header="検索キーワードを入力して Enter（ESC で戻る）" \
                --header-first \
                --height=30% \
                --print-query \
                --no-sort \
                --query="" | tail -1)
            [ -z "$QUERY" ] && continue

            show_status "$C_MAIN" "[ 検索中... ]"
            # 「表示用テキスト<TAB>動画ID<TAB>配信の状態」を1行にまとめる
            # （同名タイトルが複数あっても、IDが行ごとに紐付くのでズレない）
            # awk で、配信中・配信予定の動画に印を付け、再生時間が無いときの空の " []" を取る
            # --color no_color: 結果を加工するので色付けの制御文字を入れない
            # （以前の --no-colors は非表示の古い名前で、いずれ削除されうるため使わない）
            yt-dlp --color no_color --flat-playlist \
                --print $'[%(uploader,channel|不明)s] %(title)s [%(duration_string|)s]\t%(id)s\t%(live_status|)s' \
                "ytsearch${SEARCH_COUNT}:$QUERY" 2> "$TEMP_ERR" \
                | awk -F'\t' 'BEGIN { OFS = "\t" }
                    { sub(/ \[\]$/, "", $1) }
                    $3 == "is_live"     { $1 = "[LIVE] " $1 }
                    $3 == "is_upcoming" { $1 = "[配信予定] " $1 }
                    { print }' > "$TEMP_RESULT"

            # 「[ 検索中... ]」の行を消す（消さないと、検索するたびに画面に積み重なる）
            printf '\033[1A\r\033[2K'

            if [ ! -s "$TEMP_RESULT" ]; then
                if grep -q "ERROR" "$TEMP_ERR"; then
                    show_status "$C_ERR" "検索に失敗しました"
                    grep "ERROR" "$TEMP_ERR" | tail -n 3
                    echo "yt-dlp が古い可能性があります。$(ytdlp_update_cmd) で更新してください。"
                    wait_key
                else
                    show_status "$C_ERR" "検索結果が見つかりませんでした"
                    sleep 1
                fi
                continue
            fi

            while true; do
                {
                    printf '%s\n' "BACK     検索に戻る"
                    printf '%s\n' "EXIT     終了"
                    cat "$TEMP_RESULT"
                } > "$TEMP_LIST"

                # --delimiter/--with-nth でタブ以降(ID部分)を非表示にする。
                # 選択結果には元の行(表示部+タブ+ID)がそのまま返る。
                # --multi: Tab で複数選ぶと、まとめて保存できる
                SELECTED=$(fzf "${FZF_OPTS[@]}" \
                    --multi \
                    --header="動画を選択（マウスクリック / ↑↓ / Enter）　Tab で複数選ぶとまとめて保存" \
                    --header-first \
                    --no-sort \
                    --delimiter='\t' \
                    --with-nth=1 \
                    --height=80% < "$TEMP_LIST")

                [ -z "$SELECTED" ] && break
                # BACK / EXIT が混ざっていたら、そちらを優先する
                grep -qx "EXIT     終了" <<< "$SELECTED" && do_exit
                grep -qx "BACK     検索に戻る" <<< "$SELECTED" && break

                # 複数選ばれたら、まとめて保存へ
                if [ "$(grep -c . <<< "$SELECTED")" -gt 1 ]; then
                    mapfile -t SELECTED_LINES <<< "$SELECTED"
                    batch_download "${SELECTED_LINES[@]}"
                    continue
                fi
                SELECTED_LINE="$SELECTED"

                VIDEO_ID=$(printf '%s' "$SELECTED_LINE" | awk -F'\t' '{print $2}')
                DISPLAY_TITLE=$(printf '%s' "$SELECTED_LINE" | awk -F'\t' '{print $1}')
                LIVE_STATUS=$(printf '%s' "$SELECTED_LINE" | awk -F'\t' '{print $3}')
                if [ -z "$VIDEO_ID" ]; then
                    show_status "$C_ERR" "動画 ID の取得に失敗しました"
                    sleep 1; continue
                fi

                URL="https://www.youtube.com/watch?v=$VIDEO_ID"
                show_action_menu "$URL" "$TARGET_DIR" "$DISPLAY_TITLE" "$LIVE_STATUS"
            done
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

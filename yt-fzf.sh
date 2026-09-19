#!/bin/bash
#
# yt-fzf - fzf のメニューで YouTube 動画を検索・再生・保存するツール
#
# Copyright (c) 2026 yannsi
# SPDX-License-Identifier: MIT
# ライセンス全文は同梱の LICENSE を参照してください。

# --- 設定 ---
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
    --border-label=" [ YT-DOWNLOADER ] "
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

# 音量正規化の目標値（EBU R128 系。-16 LUFS はスマホ・PC での視聴向け）
LOUDNORM_FILTER="loudnorm=I=-16:TP=-1.5:LRA=11"

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

# 一時ファイルを作成
TEMP_RESULT=$(mktemp)   # 検索結果
TEMP_LIST=$(mktemp)     # fzf に渡す一覧
TEMP_ERR=$(mktemp)      # 検索時のエラー出力
TEMP_PATHS=$(mktemp)    # 保存されたファイルのパス
TEMP_MARKER=$(mktemp)   # ダウンロード開始時刻の目印（スキップ判定用）

cleanup() {
    rm -f "$TEMP_RESULT" "$TEMP_LIST" "$TEMP_ERR" "$TEMP_PATHS" "$TEMP_MARKER"
}
trap cleanup EXIT

do_exit() {
    clear; exit 0
}

fzf_menu() {
    # 引数: ヘッダー文字列、続けて選択肢を渡す
    local header="$1"; shift
    printf '%s\n' "$@" | fzf "${FZF_OPTS[@]}" \
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
}

# 利用可能なクリップボードツールで文字列をコピーする。
# コピーできたら 0、ツールが無ければ 1 を返す。
copy_to_clipboard() {
    local text="$1"
    if command -v wl-copy &>/dev/null; then
        printf '%s' "$text" | wl-copy && return 0
    elif command -v xclip &>/dev/null; then
        printf '%s' "$text" | xclip -selection clipboard && return 0
    elif command -v xsel &>/dev/null; then
        printf '%s' "$text" | xsel --clipboard --input && return 0
    elif command -v pbcopy &>/dev/null; then
        printf '%s' "$text" | pbcopy && return 0
    fi
    return 1
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
                do_exit ;;
            "")
                echo "$current_dir"; return ;;
            *)
                temp_dir=$(realpath "$temp_dir/$CHOICE") ;;
        esac
    done
}

# 保存済みファイルの音量を正規化して上書きする。
# 拡張子に合った形式・音質で再エンコードし、サンプルレートも元のまま保つ。
normalize_file() {
    local file="$1" mode="$2"
    local ext="${file##*.}"
    local tmp="${file%.*}.norm-tmp.${ext}"
    local rate codec_args=() video_args=(-vn)

    # loudnorm は既定で 192kHz に変換してしまうため、元のサンプルレートを指定し直す
    rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$file" 2>/dev/null)
    [[ "$rate" =~ ^[0-9]+$ ]] || rate=48000

    case "${ext,,}" in
        mp3)           codec_args=(-c:a libmp3lame -q:a 0) ;;
        m4a|mp4|aac)   codec_args=(-c:a aac -b:a 192k) ;;
        opus|webm|ogg) codec_args=(-c:a libopus -b:a 160k); rate=48000 ;;  # Opus は 48kHz 固定
        flac)          codec_args=(-c:a flac) ;;
        wav)           codec_args=(-c:a pcm_s16le) ;;
    esac
    [ "$mode" == "video" ] && video_args=(-c:v copy)   # 映像は再エンコードしない

    if ffmpeg -hide_banner -loglevel error -y -i "$file" -map_metadata 0 \
            "${video_args[@]}" -af "$LOUDNORM_FILTER" -ar "$rate" "${codec_args[@]}" "$tmp"; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# mpv でストリーミング再生する。
# $2 = yes: キャッシュを大きく取る（通常） / no: キャッシュ無効（シークで固まる場合）
play_stream() {
    local url="$1" cache="$2"
    local cache_args=(--cache=no)

    if ! command -v mpv &>/dev/null; then
        show_status "$C_ERR" "再生には mpv が必要です。パッケージマネージャでインストールしてください。"
        wait_key
        return
    fi

    [ "$cache" == "yes" ] && cache_args=(--cache=yes --demuxer-max-bytes=500MiB --demuxer-max-back-bytes=150MiB)

    show_status "$C_MAIN" "再生中... （Q キーで終了）"
    mpv \
        --geometry=50% \
        --force-window \
        "${cache_args[@]}" \
        --network-timeout=10 \
        --script-opts="ytdl_hook-ytdl_path=$(command -v yt-dlp)" \
        --ytdl-raw-options="force-ipv4=" \
        "$url" > /dev/null 2>&1
}

run_download() {
    local url="$1"
    local mode="$2"
    local output_dir="$3"
    local SECTION_ARGS=()
    local FORMAT_ARGS=()
    local OUTPUT_TMPL="%(title)s.%(ext)s"
    local DO_NORM=0
    local LABEL

    # --- 時間指定 ---
    local RANGE_CHOICE
    RANGE_CHOICE=$(fzf_menu "時間指定でダウンロードしますか？" \
        "FULL     全体をダウンロード" \
        "RANGE    範囲を指定する" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$RANGE_CHOICE" == "EXIT     終了" ] && do_exit
    if [ -z "$RANGE_CHOICE" ] || [ "$RANGE_CHOICE" == "BACK     戻る" ]; then return 0; fi

    if [ "$RANGE_CHOICE" == "RANGE    範囲を指定する" ]; then
        local RANGE_RESULT START_TIME END_TIME
        RANGE_RESULT=$(prompt_range_input)
        if [ -z "$RANGE_RESULT" ]; then return 0; fi

        START_TIME="${RANGE_RESULT%-*}"
        END_TIME="${RANGE_RESULT##*-}"
        SECTION_ARGS=(--download-sections "*${START_TIME}-${END_TIME}")
        # --force-keyframes-at-cuts は映像のカットをきれいにするための再エンコード指定。
        # 音声抽出(-x)では不要で、付けるとファイルが生成されないことがあるため動画時のみ付与。
        [ "$mode" == "video" ] && SECTION_ARGS+=(--force-keyframes-at-cuts)

        # 範囲指定時はファイル名に時間範囲を含める。
        # （全体版や他の切り抜きと名前が衝突して「ダウンロード済み」でスキップされるのを防ぐ）
        # ファイル名に使えない ":" は "-" に置換する。
        OUTPUT_TMPL="%(title)s [${START_TIME//:/-}_${END_TIME//:/-}].%(ext)s"
    fi

    # --- 音量正規化 ---
    local NORM_CHOICE
    NORM_CHOICE=$(fzf_menu "音量を正規化しますか？（ラウドネスを統一）" \
        "NO       正規化しない" \
        "YES      正規化する" \
        "BACK     戻る" \
        "EXIT     終了")
    [ "$NORM_CHOICE" == "EXIT     終了" ] && do_exit
    if [ -z "$NORM_CHOICE" ] || [ "$NORM_CHOICE" == "BACK     戻る" ]; then return 0; fi
    [ "$NORM_CHOICE" == "YES      正規化する" ] && DO_NORM=1

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
        if [ -z "$QUALITY" ] || [ "$QUALITY" == "BACK     戻る" ]; then return 0; fi

        # 1080p/720p は H.264 + AAC を優先（どの機器でも再生しやすい MP4 にする）
        case "$QUALITY" in
            "1080p / MP4") SORT="res:1080,vcodec:h264,acodec:m4a" ;;
            "720p / MP4")  SORT="res:720,vcodec:h264,acodec:m4a" ;;
            *)             SORT="res,fps,vcodec,acodec" ;;
        esac
        FORMAT_ARGS=(-S "$SORT" --merge-output-format mp4)
        LABEL="[ ダウンロード中 ]"
    else
        local AUDIO_FMT FMT
        AUDIO_FMT=$(fzf_menu "音声フォーマットを選択" \
            "MP3 (一般的)" \
            "M4A (AAC圧縮)" \
            "WAV (非圧縮)" \
            "FLAC (可逆圧縮)" \
            "BEST (自動選択)" \
            "BACK     戻る" \
            "EXIT     終了")
        [ "$AUDIO_FMT" == "EXIT     終了" ] && do_exit
        if [ -z "$AUDIO_FMT" ] || [ "$AUDIO_FMT" == "BACK     戻る" ]; then return 0; fi

        case "$AUDIO_FMT" in
            "MP3 (一般的)")    FMT="mp3"  ;;
            "M4A (AAC圧縮)")   FMT="m4a"  ;;
            "WAV (非圧縮)")    FMT="wav"  ;;
            "FLAC (可逆圧縮)") FMT="flac" ;;
            "BEST (自動選択)") FMT="best" ;;
        esac
        FORMAT_ARGS=(-x --audio-format "$FMT" --audio-quality 0)
        LABEL="[ 音声を抽出中: $FMT ]"
    fi

    # --- ダウンロード実行 ---
    echo ""
    show_status "$C_MAIN" "$LABEL  完了まで画面をそのままにしてください"
    echo ""

    : > "$TEMP_PATHS"
    touch "$TEMP_MARKER"
    # --print-to-file で保存先のパスを記録（完了表示とスキップ判定に使う）
    # --no-mtime でファイルの更新日時をダウンロード時刻にする（スキップ判定に使う）
    yt-dlp -P "$output_dir" "${FORMAT_ARGS[@]}" \
        --embed-metadata --windows-filenames --no-mtime \
        --progress --newline \
        "${SECTION_ARGS[@]}" \
        --print-to-file after_move:filepath "$TEMP_PATHS" \
        -o "$OUTPUT_TMPL" "$url"
    local exit_code=$?
    echo ""

    if [ "$exit_code" -ne 0 ]; then
        show_status "$C_ERR" "ダウンロードに失敗しました"
        echo "上記のエラーメッセージを確認してください（yt-dlp -U で更新すると直ることがあります）。"
        wait_key
        return 0
    fi

    local saved
    saved=$(tail -n 1 "$TEMP_PATHS")
    if [ -z "$saved" ] || [ ! -f "$saved" ]; then
        show_status "$C_ERR" "保存されたファイルを確認できませんでした"
        echo "  保存先フォルダ: $output_dir"
        wait_key
        return 0
    fi

    # 開始時刻より古いファイル = 今回は作られていない（同名ファイルがあってスキップされた）
    if [ ! "$saved" -nt "$TEMP_MARKER" ]; then
        show_status "$C_ERR" "同じ名前のファイルが既にあるため、ダウンロードをスキップしました"
        echo "  既存ファイル: $saved"
        echo "  作り直す場合は、既存ファイルを削除するか名前を変えてから実行してください。"
        wait_key
        return 0
    fi

    if [ "$DO_NORM" -eq 1 ]; then
        show_status "$C_MAIN" "[ 音量を正規化中 ]"
        if ! normalize_file "$saved" "$mode"; then
            show_status "$C_ERR" "音量の正規化に失敗しました（ダウンロードしたファイルはそのまま残っています）"
            echo "  保存先: $saved"
            wait_key
            return 0
        fi
    fi

    show_status "$C_OK" "[ 完了 ]"
    echo "  保存先: $saved"
    wait_key
}

show_action_menu() {
    local url="$1"
    local target_dir="$2"
    local title="$3"

    while true; do
        local ACTION
        ACTION=$(fzf_menu "操作を選択  |  $title" \
            "STREAM   ストリーミング再生" \
            "STREAM2  ストリーミング再生（シークで固まる場合）" \
            "VIDEO    動画保存" \
            "AUDIO    音声保存" \
            "URL      URLを確認 / コピー" \
            "BACK     戻る" \
            "EXIT     終了")

        [ "$ACTION" == "EXIT     終了" ] && do_exit
        if [ -z "$ACTION" ] || [ "$ACTION" == "BACK     戻る" ]; then return 0; fi

        case "$ACTION" in
            "STREAM   ストリーミング再生")
                play_stream "$url" yes ;;
            "STREAM2  ストリーミング再生（シークで固まる場合）")
                play_stream "$url" no ;;
            "VIDEO    動画保存")
                run_download "$url" "video" "$target_dir" ;;
            "AUDIO    音声保存")
                run_download "$url" "audio" "$target_dir" ;;
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

show_help() {
    local name
    name=$(basename "$0")
    cat <<EOF
使い方: ${name} [オプション]

fzf のメニューで YouTube 動画を検索・再生・保存するツールです。
オプションなしで起動するとメニューが開きます。

オプション:
  -h, --help    このヘルプを表示して終了

メインメニュー:
  SEARCH   キーワードで検索（上位15件）
  URL      URL を直接入力
  CONFIG   保存先フォルダを変更（次回以降も記憶）
  EXIT     終了

動画を選んだあとの操作:
  STREAM   ストリーミング再生（Q で終了）
  STREAM2  ストリーミング再生（STREAM で早送りすると固まる場合）
  VIDEO    動画保存（1080p / 720p / 最高画質、MP4）
  AUDIO    音声保存（MP3 / M4A / WAV / FLAC / 自動選択）
  URL      動画の URL を表示してクリップボードにコピー

保存時の設定:
  時間指定  「開始-終了」で範囲を切り出し（例: 0:00-1:00、1:20:00-1:25:30）
            ファイル名に範囲が付きます（例: タイトル [0-00_1-00].mp3）
  音量正規化  音量をそろえます（形式・サンプルレートは元のまま）

操作:
  ↑↓ / マウス で選択、Enter で決定、ESC または BACK で戻る

必要なもの:
  fzf, yt-dlp, ffmpeg（ffprobe）  必須
  mpv                             再生するときのみ
  wl-copy / xclip / xsel          URL の自動コピーを使うときのみ

保存先の記録: ${LAST_DIR_FILE}
現在の保存先: ${TARGET_DIR}

うまく動かないときは、まず yt-dlp -U で yt-dlp を更新してください。
EOF
}

# --- メイン処理 ---

# 起動オプション（ツールが未インストールでもヘルプは見られるよう、依存チェックより前に処理）
case "$1" in
    "") ;;
    -h|--help)
        show_help
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

while true; do
    MODE=$(fzf_menu "保存先: $(basename "$TARGET_DIR")" \
        "SEARCH   キーワードで検索" \
        "URL      URLを入力" \
        "CONFIG   保存先を変更" \
        "EXIT     終了")

    [ -z "$MODE" ] || [ "$MODE" == "EXIT     終了" ] && do_exit

    if [ "$MODE" == "CONFIG   保存先を変更" ]; then
        TARGET_DIR=$(select_directory "$TARGET_DIR")
        echo "$TARGET_DIR" > "$LAST_DIR_FILE"
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
        [ -n "$URL" ] && show_action_menu "$URL" "$TARGET_DIR" "URL 指定の動画"
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
        # 表示用テキストと動画IDをタブで区切って1行にまとめる
        # （同名タイトルが複数あっても、IDが行ごとに紐付くのでズレない）
        yt-dlp --no-colors --flat-playlist \
            --print $'[%(uploader,channel|不明)s] %(title)s [%(duration_string|)s]\t%(id)s' \
            "ytsearch15:$QUERY" > "$TEMP_RESULT" 2> "$TEMP_ERR"

        if [ ! -s "$TEMP_RESULT" ]; then
            if grep -q "ERROR" "$TEMP_ERR"; then
                show_status "$C_ERR" "検索に失敗しました"
                grep "ERROR" "$TEMP_ERR" | tail -n 3
                echo "yt-dlp が古い可能性があります。yt-dlp -U で更新してください。"
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
            SELECTED_LINE=$(fzf "${FZF_OPTS[@]}" \
                --header="動画を選択（マウスクリック / ↑↓ / Enter）" \
                --header-first \
                --no-sort \
                --delimiter='\t' \
                --with-nth=1 \
                --height=80% < "$TEMP_LIST")

            [ "$SELECTED_LINE" == "EXIT     終了" ] && do_exit
            if [ -z "$SELECTED_LINE" ] || [ "$SELECTED_LINE" == "BACK     検索に戻る" ]; then break; fi

            VIDEO_ID=$(printf '%s' "$SELECTED_LINE" | awk -F'\t' '{print $2}')
            DISPLAY_TITLE=$(printf '%s' "$SELECTED_LINE" | awk -F'\t' '{print $1}')
            if [ -z "$VIDEO_ID" ]; then
                show_status "$C_ERR" "動画 ID の取得に失敗しました"
                sleep 1; continue
            fi

            URL="https://www.youtube.com/watch?v=$VIDEO_ID"
            show_action_menu "$URL" "$TARGET_DIR" "$DISPLAY_TITLE"
        done
    fi
done

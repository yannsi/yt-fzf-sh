#!/bin/bash

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
TEMP_RESULT=$(mktemp)
TEMP_LIST=$(mktemp)

cleanup() {
    rm -f "$TEMP_RESULT" "$TEMP_LIST"
    tput cnorm
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

# 時間の1区間(TIME単体、H:M:S/M:S/秒)が正しい形式かどうかを判定
_is_valid_time() {
    [[ "$1" =~ ^(([0-9]+:)?[0-9]{1,2}:[0-9]{2}|[0-9]+)$ ]]
}

# 「開始-終了」の形式でまとめて範囲を入力させる。
# 例: 0:00-1:00 / 1:20:00-1:25:30
# 空入力(ESC)なら空文字を返す。不正な形式なら再入力を求める。
prompt_range_input() {
    local input start end
    while true; do
        input=$(echo "" | fzf "${FZF_OPTS[@]}" \
            --header="範囲を「開始-終了」で入力  例: 0:00-1:00 / 1:20:00-1:25:30（ESCで戻る）" \
            --header-first --height=30% --print-query --no-sort --query="" | tail -1)

        if [ -z "$input" ]; then
            echo ""
            return
        fi

        if [[ "$input" != *-* ]]; then
            show_status "$C_ERR" "「開始-終了」のように - (ハイフン) で区切って入力してください　例: 0:00-1:00"
            sleep 1.5
            continue
        fi

        start="${input%-*}"
        end="${input##*-}"

        if _is_valid_time "$start" && _is_valid_time "$end"; then
            echo "${start}-${end}"
            return
        fi

        show_status "$C_ERR" "時間の形式が正しくありません。分:秒（例 1:30）または 時:分:秒（例 1:20:00）で入力してください"
        sleep 1.5
    done
}

# フォルダのみを選択する独自ブラウザ
select_directory() {
    local current_dir="$1"
    local temp_dir="$current_dir"
    [ ! -d "$temp_dir" ] && temp_dir="$HOME"

    while true; do
        local folders
        folders=$(ls -F "$temp_dir" 2>/dev/null | grep '/$' | sed 's/\/$//')

        local CHOICE
        CHOICE=$(printf '%s\n' \
            "BACK     戻る (変更しない)" \
            "SELECT   このフォルダに決定" \
            "UP       .. (上の階層へ)" \
            "EXIT     終了" \
            $folders \
            | fzf "${FZF_OPTS[@]}" \
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

run_download() {
    local url="$1"
    local mode="$2"
    local output_dir="$3"
    local QUALITY AUDIO_FMT FMT exit_code
    local SECTION_ARGS=()
    local NORM_ARGS=()
    local NORM_TMP_EXT="mp4"
    local OUTPUT_TMPL="%(title)s.%(ext)s"

    # --- 時間指定 ---
    local RANGE_CHOICE
    RANGE_CHOICE=$(fzf_menu "時間指定でダウンロードしますか？" \
        "FULL     全体をダウンロード" \
        "RANGE    範囲を指定する" \
        "BACK" \
        "EXIT     終了")
    [ "$RANGE_CHOICE" == "EXIT     終了" ] && do_exit
    if [ -z "$RANGE_CHOICE" ] || [ "$RANGE_CHOICE" == "BACK" ]; then return 0; fi

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
        local RANGE_LABEL="${START_TIME//:/-}_${END_TIME//:/-}"
        OUTPUT_TMPL="%(title)s [${RANGE_LABEL}].%(ext)s"
    fi

    # --- 音量正規化 ---
    local NORM_CHOICE
    NORM_CHOICE=$(fzf_menu "音量を正規化しますか？（ラウドネスを統一）" \
        "NO       正規化しない" \
        "YES      正規化する" \
        "BACK" \
        "EXIT     終了")
    [ "$NORM_CHOICE" == "EXIT     終了" ] && do_exit
    if [ -z "$NORM_CHOICE" ] || [ "$NORM_CHOICE" == "BACK" ]; then return 0; fi

    if [ "$mode" == "video" ]; then
        QUALITY=$(fzf_menu "画質を選択" \
            "BACK" \
            "1080p / MP4" \
            "720p / MP4" \
            "BEST QUALITY" \
            "EXIT     終了")
        [ "$QUALITY" == "EXIT     終了" ] && do_exit
        if [ -z "$QUALITY" ] || [ "$QUALITY" == "BACK" ]; then return 0; fi

        [ "$NORM_CHOICE" == "YES      正規化する" ] && NORM_ARGS=(--exec "ffmpeg -y -i %(filepath)q -map_metadata 0 -c:v copy -af loudnorm=I=-16:TP=-1.5:LRA=11 %(filepath)q.norm.${NORM_TMP_EXT} && mv -f %(filepath)q.norm.${NORM_TMP_EXT} %(filepath)q")

        echo ""
        show_status "$C_MAIN" "[ ダウンロード中 ]  完了まで画面をそのままにしてください"
        echo ""
        case "$QUALITY" in
            "1080p / MP4")  yt-dlp -P "$output_dir" -S "res:1080,fps,vcodec,acodec" --merge-output-format mp4 --embed-metadata --windows-filenames --progress --newline "${SECTION_ARGS[@]}" "${NORM_ARGS[@]}" -o "$OUTPUT_TMPL" "$url" ;;
            "720p / MP4")   yt-dlp -P "$output_dir" -S "res:720,fps,vcodec,acodec"  --merge-output-format mp4 --embed-metadata --windows-filenames --progress --newline "${SECTION_ARGS[@]}" "${NORM_ARGS[@]}" -o "$OUTPUT_TMPL" "$url" ;;
            "BEST QUALITY") yt-dlp -P "$output_dir" -S "res,fps,vcodec,acodec"      --merge-output-format mp4 --embed-metadata --windows-filenames --progress --newline "${SECTION_ARGS[@]}" "${NORM_ARGS[@]}" -o "$OUTPUT_TMPL" "$url" ;;
        esac
    else
        AUDIO_FMT=$(fzf_menu "音声フォーマットを選択" \
            "BACK" \
            "MP3 (一般的)" \
            "M4A (AAC圧縮)" \
            "WAV (非圧縮)" \
            "FLAC (可逆圧縮)" \
            "BEST (自動選択)" \
            "EXIT     終了")
        [ "$AUDIO_FMT" == "EXIT     終了" ] && do_exit
        if [ -z "$AUDIO_FMT" ] || [ "$AUDIO_FMT" == "BACK" ]; then return 0; fi

        case "$AUDIO_FMT" in
            "MP3 (一般的)")    FMT="mp3"  ;;
            "M4A (AAC圧縮)")   FMT="m4a"  ;;
            "WAV (非圧縮)")    FMT="wav"  ;;
            "FLAC (可逆圧縮)") FMT="flac" ;;
            "BEST (自動選択)") FMT="best" ;;
        esac
        # BEST 選択時、正規化のための再エンコード先コンテナは m4a を使用
        NORM_TMP_EXT="$FMT"; [ "$NORM_TMP_EXT" == "best" ] && NORM_TMP_EXT="m4a"

        [ "$NORM_CHOICE" == "YES      正規化する" ] && NORM_ARGS=(--exec "ffmpeg -y -i %(filepath)q -map_metadata 0 -af loudnorm=I=-16:TP=-1.5:LRA=11 %(filepath)q.norm.${NORM_TMP_EXT} && mv -f %(filepath)q.norm.${NORM_TMP_EXT} %(filepath)q")

        echo ""
        show_status "$C_MAIN" "[ 音声を抽出中: $FMT ]  完了まで画面をそのままにしてください"
        echo ""
        yt-dlp -P "$output_dir" -x --audio-format "$FMT" --audio-quality 0 --embed-metadata --windows-filenames --progress --newline "${SECTION_ARGS[@]}" "${NORM_ARGS[@]}" -o "$OUTPUT_TMPL" "$url"
    fi

    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        show_status "$C_OK" "[ 完了 ]"
        sleep 1
    else
        show_status "$C_ERR" "ダウンロードに失敗しました"
        echo "上記のエラーメッセージを確認してください。"
        echo "キーを押すとメニューに戻ります..."
        read -n 1
    fi
}

show_action_menu() {
    local url="$1"
    local target_dir="$2"
    local title="$3"

    while true; do
        local ACTION
        ACTION=$(fzf_menu "操作を選択  |  $title" \
            "STREAM   ストリーミング再生" \
            "VIDEO    動画保存" \
            "AUDIO    音声保存" \
            "URL      URLを確認 / コピー" \
            "BACK     戻る" \
            "EXIT     終了")

        [ "$ACTION" == "EXIT     終了" ] && do_exit
        if [ -z "$ACTION" ] || [ "$ACTION" == "BACK     戻る" ]; then return 0; fi

        case "$ACTION" in
            "STREAM   ストリーミング再生")
                show_status "$C_MAIN" "再生中... （Q キーで終了）"
                local ytdlp_path
                ytdlp_path=$(which yt-dlp)
                mpv \
                    --really-quiet \
                    --geometry=50% \
                    --force-window \
                    --script-opts="ytdl_hook-ytdl_path=${ytdlp_path}" \
                    --ytdl-raw-options="force-ipv4=" \
                    "$url" > /dev/null 2>&1
                ;;
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
                echo "キーを押すとメニューに戻ります..."
                read -n 1
                ;;
            "VIDEO    動画保存")
                run_download "$url" "video" "$target_dir" ;;
            "AUDIO    音声保存")
                run_download "$url" "audio" "$target_dir" ;;
        esac
    done
}

# --- メイン処理 ---

check_dependency fzf
check_dependency yt-dlp
check_dependency mpv
check_dependency ffmpeg

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
            "ytsearch15:$QUERY" > "$TEMP_RESULT" 2>/dev/null

        if [ ! -s "$TEMP_RESULT" ]; then
            show_status "$C_ERR" "検索結果が見つかりませんでした"
            sleep 1; continue
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

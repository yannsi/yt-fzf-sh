#!/bin/bash
#
# yt-fzf を自分のホームフォルダ（~/.local/bin）にインストール / アンインストールする。
# sudo は不要です。
#
#   bash install.sh             インストール（アップデートも同じ）
#   bash install.sh uninstall   アンインストール
#
# Copyright (c) 2026 yannsi
# SPDX-License-Identifier: MIT

set -u

APP_NAME="yt-fzf"
BIN_DIR="${HOME}/.local/bin"
DEST="${BIN_DIR}/${APP_NAME}"
CONFIG_DIR="${HOME}/.yt-downloader"

# このスクリプトが置いてあるフォルダ（どこから実行しても本体を見つけられるように）
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC_DIR}/yt-fzf.sh"

ok()   { echo -e "\033[38;5;46m$*\033[0m"; }
warn() { echo -e "\033[38;5;214m$*\033[0m"; }
err()  { echo -e "\033[38;5;196m$*\033[0m" >&2; }

# 足りないツールを調べて、入れ方を案内する（インストール自体は止めない）
check_dependencies() {
    local missing_required=() missing_optional=()
    local cmd

    for cmd in fzf yt-dlp ffmpeg ffprobe; do
        command -v "$cmd" &>/dev/null || missing_required+=("$cmd")
    done
    command -v mpv &>/dev/null || missing_optional+=("mpv")

    if [ ${#missing_required[@]} -eq 0 ] && [ ${#missing_optional[@]} -eq 0 ]; then
        ok "必要なツールはすべてそろっています。"
        return
    fi

    # ffprobe は ffmpeg パッケージに入っているので、パッケージ名にまとめる
    local pkgs=() p
    for p in "${missing_required[@]}" "${missing_optional[@]}"; do
        [ "$p" == "ffprobe" ] && p="ffmpeg"
        [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
    done

    echo ""
    if [ ${#missing_required[@]} -gt 0 ]; then
        warn "次の必須ツールが見つかりません: ${missing_required[*]}"
        warn "このままでは yt-fzf を起動できません。"
    fi
    if [ ${#missing_optional[@]} -gt 0 ]; then
        warn "再生用の mpv が見つかりません（保存だけなら無くても使えます）。"
    fi

    echo "インストールするには次のコマンドを実行してください:"
    if command -v pacman &>/dev/null; then
        echo "  sudo pacman -S --needed ${pkgs[*]}"
    elif command -v apt &>/dev/null; then
        echo "  sudo apt install ${pkgs[*]}"
        if [[ " ${pkgs[*]} " == *" yt-dlp "* ]]; then
            echo "  （yt-dlp は apt 版が古いことが多いので、README の配布バイナリを使う方法がおすすめです）"
        fi
    else
        echo "  お使いのパッケージマネージャで ${pkgs[*]} をインストールしてください"
    fi
}

# ~/.local/bin が PATH に入っているか確認する
check_path() {
    case ":${PATH}:" in
        *":${BIN_DIR}:"*) return ;;
    esac
    echo ""
    warn "${BIN_DIR} が PATH に入っていないため、このままでは「yt-fzf」で起動できません。"
    # shellcheck disable=SC2088  # 表示用の文字列なので ~ は展開しなくてよい
    echo "~/.bashrc に次の1行を追加して、ターミナルを開き直してください:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
}

do_install() {
    if [ ! -f "$SRC" ]; then
        err "本体の yt-fzf.sh が見つかりません: $SRC"
        err "git clone したフォルダの中で実行してください。"
        exit 1
    fi

    local action="インストール"
    [ -f "$DEST" ] && action="アップデート"

    mkdir -p "$BIN_DIR" || { err "${BIN_DIR} を作成できませんでした。"; exit 1; }
    if ! install -m 755 "$SRC" "$DEST"; then
        err "${DEST} へのコピーに失敗しました。"
        exit 1
    fi

    ok "${action}しました: ${DEST}"
    check_dependencies
    check_path
    echo ""
    echo "起動: ${APP_NAME}　　ヘルプ: ${APP_NAME} -h"
}

do_uninstall() {
    if [ ! -f "$DEST" ]; then
        warn "${DEST} は見つかりませんでした（インストールされていません）。"
    elif rm -f "$DEST"; then
        ok "アンインストールしました: ${DEST}"
    else
        err "${DEST} を削除できませんでした。"
        exit 1
    fi

    if [ -d "$CONFIG_DIR" ]; then
        echo "保存先の設定（${CONFIG_DIR}）は残してあります。不要なら次のコマンドで削除できます:"
        echo "  rm -r \"${CONFIG_DIR}\""
    fi
}

case "${1:-}" in
    "" | install)
        do_install ;;
    uninstall)
        do_uninstall ;;
    -h | --help)
        echo "使い方: bash install.sh [install | uninstall]"
        echo "  （引数なし）  ${DEST} にインストール（アップデートも同じ）"
        echo "  uninstall     ${DEST} を削除"
        ;;
    *)
        err "不明な指定です: $1"
        echo "使い方: bash install.sh [install | uninstall]" >&2
        exit 1 ;;
esac

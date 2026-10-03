# Maintainer: yannsi
#
# git clone したフォルダの中で makepkg -si を実行するとインストールできます。
# （同じフォルダにある yt-fzf.sh / LICENSE / README.md をパッケージにします）

pkgname=yt-fzf
pkgver=1.0.2
pkgrel=1
pkgdesc="Search, stream and download YouTube videos from an fzf menu"
arch=('any')
url="https://github.com/yannsi/yt-fzf-sh"
license=('MIT')
depends=('bash' 'fzf' 'yt-dlp' 'ffmpeg')
# 以前は yt-fzf-sh という名前でパッケージにしていたため、同じ /usr/bin/yt-fzf を持つ。
# 入れ替えられるようにしておく（インストール時に yt-fzf-sh を削除するか聞かれる）。
conflicts=('yt-fzf-sh')
replaces=('yt-fzf-sh')
optdepends=(
    'mpv: streaming playback'
    'wl-clipboard: copy URL to clipboard (Wayland)'
    'xclip: copy URL to clipboard (X11)'
    'xsel: copy URL to clipboard (X11)'
)
source=('yt-fzf.sh' 'LICENSE' 'README.md')
sha256sums=('SKIP' 'SKIP' 'SKIP')

package() {
    install -Dm755 "$srcdir/yt-fzf.sh" "$pkgdir/usr/bin/yt-fzf"
    install -Dm644 "$srcdir/LICENSE"   "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    install -Dm644 "$srcdir/README.md" "$pkgdir/usr/share/doc/$pkgname/README.md"
}

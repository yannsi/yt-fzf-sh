# Maintainer: sk <sk@localhost>
pkgname=yt-fzf-sh
pkgver=1.0.0
pkgrel=1
pkgdesc="Interactive YouTube downloader and streamer using fzf and yt-dlp"
arch=('any')
license=('custom')
depends=('bash' 'fzf' 'yt-dlp' 'mpv' 'ffmpeg')
optdepends=(
  'wl-clipboard: Wayland clipboard support'
  'xclip: X11 clipboard support'
  'xsel: X11 clipboard support'
)
source=('yt-fzf.sh')
sha256sums=('SKIP')

package() {
  install -Dm755 "${srcdir}/yt-fzf.sh" "${pkgdir}/usr/bin/yt-fzf"
}

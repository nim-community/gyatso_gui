# Package

version       = "0.1.0"
author        = "bung87"
description   = "A sleek, high-performance chess GUI for Gyatso Chess Engine"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim","png","wav","bin"]
bin           = @["gyatso_gui"]


# Dependencies

requires "nim >= 2.2.4"
requires "nglfw"
requires "pixie"
requires "vmath"
requires "opengl"

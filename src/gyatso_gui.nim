import nglfw, opengl
import std/[times, monotimes, atomics, math, os]
import vmath
import pixie

import gyatso_gui/[
  coretypes,
  board,
  move,
  movegen,
  search,
  evaluation,
  zobrist,
  tt,
  lookups,
  magicbitboards,
  threading,
  audio
]


const
  ScreenWidth = 1024
  ScreenHeight = 768
  BoardSize = 640
  SquareSize = BoardSize div 8
  BoardX = 50
  BoardY = (ScreenHeight - BoardSize) div 2
  FontSize = 20.0f


type
  UIPiece = enum
    uiNone,
    uiwp, uiwn, uiwb, uiwr, uiwq, uiwk,
    uibp, uibn, uibb, uibr, uibq, uibk

  GameState = object
    board: Board
    selectedSq: int
    moveHistory: seq[string]
    whiteToMove: bool
    thinking: bool
    autoMove: bool
    searchDepth: int
    stopFlag: Atomic[bool]

  Color4 = tuple[r,g,b,a: float32]

# Piece texture array indices match UIPiece enum (uiNone=0 unused)
var pieceTextures: array[13, GLuint]


const
  CLight: Color4 = (0.94.float32, 0.85, 0.71, 1.0)
  CDark: Color4 = (0.71, 0.53, 0.39, 1.0)
  CSelect: Color4 = (0.97, 0.91, 0.36, 0.7)
  # Warm color scheme matching the cream background
  CPanel: Color4 = (0.93, 0.88, 0.74, 1.0)
  CPanelBorder: Color4 = (0.75, 0.65, 0.45, 1.0)
  CButton: Color4 = (0.62, 0.48, 0.35, 1.0)
  CButtonHover: Color4 = (0.72, 0.56, 0.42, 1.0)
  CButtonActive: Color4 = (0.52, 0.40, 0.28, 1.0)
  CTextDark: Color4 = (0.35, 0.25, 0.15, 1.0)
  CWhitePiece: Color4 = (0.95, 0.95, 0.95, 1.0)
  CBlackPiece: Color4 = (0.1, 0.1, 0.1, 1.0)


var
  game: GameState
  mouseX, mouseY: float64
  mousePressed, mouseReleased: bool
  font: Font
  # Cached text textures
  lastStatusText: string
  titleCached: bool = false
  # Board coordinate textures (a-h, 1-8)
  coordLabelsCached: bool = false
  # Move history cache
  lastMoveHistoryLen: int = 0
  historyTitleCached: bool = false

# 缓存按钮文字纹理
type ButtonTex = object
  id: GLuint
  width, height: int
var btn1Tex, btn2Tex, btn3Tex: ButtonTex

# Cached text textures (after type definition)
var
  titleTexCached: ButtonTex
  statusTexCached: ButtonTex
  # Board coordinate textures (a-h, 1-8)
  fileLabelTex: array[8, ButtonTex]
  rankLabelTex: array[8, ButtonTex]
  # Move history cache
  moveHistoryTexCached: seq[ButtonTex] = @[]
  historyTitleTexCached: ButtonTex

# Piece image data (embedded using staticRead)
const PieceImageData = block:
  const basePath = currentSourcePath().parentDir / "../assets/pieces/"
  [
    "",  # uiNone = 0, placeholder
    staticRead(basePath / "wp.png"),  # uiwp = 1
    staticRead(basePath / "wn.png"),  # uiwn = 2
    staticRead(basePath / "wb.png"),  # uiwb = 3
    staticRead(basePath / "wr.png"),  # uiwr = 4
    staticRead(basePath / "wq.png"),  # uiwq = 5
    staticRead(basePath / "wk.png"),  # uiwk = 6
    staticRead(basePath / "bp.png"),  # uibp = 7
    staticRead(basePath / "bn.png"),  # uibn = 8
    staticRead(basePath / "bb.png"),  # uibb = 9
    staticRead(basePath / "br.png"),  # uibr = 10
    staticRead(basePath / "bq.png"),  # uibq = 11
    staticRead(basePath / "bk.png"),  # uibk = 12
  ]


proc loadTextureFromMemory(data: string): GLuint =
  ## Load PNG data from memory and create OpenGL texture
  var image = decodeImage(data)
  let width = image.width
  let height = image.height

  # 转换为 RGBA 字节序列
  var pixels = newSeq[uint8](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let color = image[x, y]
      let idx = (y * width + x) * 4
      pixels[idx + 0] = color.r
      pixels[idx + 1] = color.g
      pixels[idx + 2] = color.b
      pixels[idx + 3] = color.a

  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)

  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA.GLint, width.GLsizei, height.GLsizei,
               0, GL_RGBA, GL_UNSIGNED_BYTE, addr pixels[0])

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)

proc initPieceTextures() =
  ## Initialize all piece textures
  for i in 1 .. 12:  # 跳过 uiNone (0)
    pieceTextures[i] = loadTextureFromMemory(PieceImageData[i])

proc isFontLoaded(f: Font): bool =
  return f != nil and f.typeface != nil and f.typeface.filePath != ""

proc loadSystemFont(): Font =
  # Try to load common system fonts (TTF only, not TTC collections)
  let fontPaths = @[
    "/Library/Fonts/SF-Pro.ttf",            # macOS San Francisco
    "/Library/Fonts/Arial Unicode.ttf",     # macOS Arial
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",  # Linux
    "C:/Windows/Fonts/arial.ttf",           # Windows
  ]
  for path in fontPaths:
    if fileExists(path):
      try:
        result = readFont(path)
        if result.isFontLoaded:
          return result
      except Exception as e:
        echo "Failed to load font ", path, ": ", e.msg
        continue
  # If no system font found, return nil font
  result = nil

proc initTextRendering() =
  font = loadSystemFont()
  if font.isFontLoaded:
    echo "Font loaded: ", font.typeface.filePath
    font.size = FontSize
    font.paint = newPaint(SolidPaint)
    font.paint.color = color(1, 1, 1, 1)
  else:
    echo "Warning: No system font found, button text disabled"

proc renderTextToTexture(text: string, w, h: int, bgColor, textColor: pixie.Color): ButtonTex =
  if not font.isFontLoaded:
    return ButtonTex()

  let image = newImage(w, h)

  # Fill background
  image.fill(bgColor)

  # Calculate text position (centered)
  let bounds = font.layoutBounds(text)
  let tx = (w.float32 - bounds.x) / 2
  let ty = (h.float32 - bounds.y) / 2

  # Draw text with specified color
  font.paint.color = textColor
  image.fillText(font, text, translate(vec2(tx, ty)))

  # Convert to OpenGL texture
  var texId: GLuint
  glGenTextures(1, addr texId)
  glBindTexture(GL_TEXTURE_2D, texId)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)

  # Convert image data to raw bytes for OpenGL
  var pixels = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let color = image[x, y]
      let idx = (y * w + x) * 4
      pixels[idx + 0] = color.r
      pixels[idx + 1] = color.g
      pixels[idx + 2] = color.b
      pixels[idx + 3] = color.a

  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA.GLint, w.GLsizei, h.GLsizei,
               0, GL_RGBA, GL_UNSIGNED_BYTE, addr pixels[0])


  result = ButtonTex(id: texId, width: w, height: h)

proc drawTexture(tex: ButtonTex, x, y: float32) =
  if tex.id == 0: return

  glEnable(GL_TEXTURE_2D)
  glBindTexture(GL_TEXTURE_2D, tex.id)
  glColor4f(1, 1, 1, 1)

  let x1 = (x / ScreenWidth.float32) * 2.0f - 1.0f
  let y1 = 1.0f - (y / ScreenHeight.float32) * 2.0f
  let x2 = ((x + tex.width.float32) / ScreenWidth.float32) * 2.0f - 1.0f
  let y2 = 1.0f - ((y + tex.height.float32) / ScreenHeight.float32) * 2.0f

  glBegin(GL_QUADS)
  glTexCoord2f(0, 1); glVertex2f(x1, y2)
  glTexCoord2f(1, 1); glVertex2f(x2, y2)
  glTexCoord2f(1, 0); glVertex2f(x2, y1)
  glTexCoord2f(0, 0); glVertex2f(x1, y1)
  glEnd()
  glDisable(GL_TEXTURE_2D)

proc rect(x, y, w, h: float32, c: Color4) =
  glDisable(GL_TEXTURE_2D)
  glColor4f(c.r, c.g, c.b, c.a)
  let x1 = (x / ScreenWidth.float32) * 2.0f - 1.0f
  let y1 = 1.0f - (y / ScreenHeight.float32) * 2.0f
  let x2 = ((x + w) / ScreenWidth.float32) * 2.0f - 1.0f
  let y2 = 1.0f - ((y + h) / ScreenHeight.float32) * 2.0f
  glBegin(GL_QUADS)
  glVertex2f(x1, y2)
  glVertex2f(x2, y2)
  glVertex2f(x2, y1)
  glVertex2f(x1, y1)
  glEnd()

proc drawTexturedPiece(x, y, size: float32, textureId: GLuint) =
  ## Draw textured piece
  glEnable(GL_TEXTURE_2D)
  glBindTexture(GL_TEXTURE_2D, textureId)
  glColor4f(1.0f, 1.0f, 1.0f, 1.0f)

  let x1 = (x / ScreenWidth.float32) * 2.0f - 1.0f
  let y1 = 1.0f - (y / ScreenHeight.float32) * 2.0f
  let x2 = ((x + size) / ScreenWidth.float32) * 2.0f - 1.0f
  let y2 = 1.0f - ((y + size) / ScreenHeight.float32) * 2.0f

  glBegin(GL_QUADS)
  glTexCoord2f(0.0f, 1.0f); glVertex2f(x1, y2)  # flip Y
  glTexCoord2f(1.0f, 1.0f); glVertex2f(x2, y2)
  glTexCoord2f(1.0f, 0.0f); glVertex2f(x2, y1)
  glTexCoord2f(0.0f, 0.0f); glVertex2f(x1, y1)
  glEnd()

  glDisable(GL_TEXTURE_2D)

proc circle(x, y, r: float32, c: Color4) =
  glDisable(GL_TEXTURE_2D)
  glColor4f(c.r, c.g, c.b, c.a)
  let cx = (x / ScreenWidth.float32) * 2.0f - 1.0f
  let cy = 1.0f - (y / ScreenHeight.float32) * 2.0f
  let rx = (r / ScreenWidth.float32) * 2.0f
  let ry = (r / ScreenHeight.float32) * 2.0f
  glBegin(GL_TRIANGLE_FAN)
  glVertex2f(cx, cy)
  for i in 0..32:
    let a = i.float32 * PI / 16.0f
    glVertex2f(cx + cos(a) * rx, cy + sin(a) * ry)
  glEnd()


proc boardToUIPieces(board: Board): array[64, UIPiece] =
  for sq in 0..63:
    let piece = board.pieces[sq.Square]
    result[sq] = case piece
      of WhitePawn: uiwp
      of WhiteKnight: uiwn
      of WhiteBishop: uiwb
      of WhiteRook: uiwr
      of WhiteQueen: uiwq
      of WhiteKing: uiwk
      of BlackPawn: uibp
      of BlackKnight: uibn
      of BlackBishop: uibb
      of BlackRook: uibr
      of BlackQueen: uibq
      of BlackKing: uibk
      of NoPiece: uiNone

proc uiPieceToChar(p: UIPiece): char {.used.} =
  case p
  of uiwp: 'P'
  of uiwn: 'N'
  of uiwb: 'B'
  of uiwr: 'R'
  of uiwq: 'Q'
  of uiwk: 'K'
  of uibp: 'p'
  of uibn: 'n'
  of uibb: 'b'
  of uibr: 'r'
  of uibq: 'q'
  of uibk: 'k'
  of uiNone: ' '

proc squareToUCI(sq: int): string =
  ## Convert internal square to UCI notation
  ## Internal square 52 -> rank 6, file 4 -> chess rank 7, file e -> "e7"
  if sq < 0 or sq > 63: return ""
  let file = chr(ord('a') + (sq mod 8))
  let rank = chr(ord('1') + (sq div 8))  # rank 0-7 -> '1'-'8'
  result = $file & $rank

proc uciToSquare(uci: string): Square =
  ## Convert UCI square notation to internal square
  ## UCI "e7" -> chess rank 7, file e -> internal rank 6, file 4 -> square 52
  if uci.len < 2: return 0.Square
  let file = ord(uci[0]) - ord('a')  # 0-7 (a-h)
  let rank = ord(uci[1]) - ord('1')  # 0-7 (rank 1-8)
  # Internal: rank 0 = chess rank 1, rank 7 = chess rank 8
  result = (rank * 8 + file).Square

proc parseUCIMove(board: var Board, uci: string): Move =
  if uci.len < 4: return Move(0)

  let fromSq = uciToSquare(uci[0..1])
  let toSq = uciToSquare(uci[2..3])

  var promo = NoPieceType
  if uci.len > 4:
    promo = case uci[4]
      of 'n', 'N': Knight
      of 'b', 'B': Bishop
      of 'r', 'R': Rook
      of 'q', 'Q': Queen
      else: NoPieceType

  var ml: MoveList
  generateLegalMoves(board, ml)

  for i in 0 ..< ml.count:
    let m = ml.moves[i]
    if m.fromSquare == fromSq and m.toSquare == toSq:
      if promo == NoPieceType or m.promotion == promo:
        return m

  return Move(0)


proc initGame*() =
  precomputeAttackTables()
  initMagicBitboards()
  initializeZobristKeys()
  initTT(32)  # Reduced from 64MB - 32MB is plenty for fast searches
  initNNUE()
  initThreadPool(1)
  initPieceTextures()
  initTextRendering()

  # Create button text textures with warm color scheme
  let btnBg = color(CButton.r, CButton.g, CButton.b, 1.0)
  let btnTextColor = color(0.98, 0.96, 0.92, 1.0)
  btn1Tex = renderTextToTexture("Engine Move", 180, 36, btnBg, btnTextColor)
  btn2Tex = renderTextToTexture("New Game", 140, 36, btnBg, btnTextColor)
  btn3Tex = renderTextToTexture("Auto: OFF", 120, 36, btnBg, btnTextColor)

  game.board = initializeBoard()
  game.selectedSq = -1
  game.whiteToMove = true
  game.searchDepth = 12  # Reduced from 15 for faster response
  game.stopFlag.store(false)




# Threading channels for engine communication
var
  engineInputChan: Channel[string]  # FEN string
  engineOutputChan: Channel[string] # "move" or ""
  engineThread: Thread[void]
  engineRunning: Atomic[bool]

proc engineWorker() {.thread.} =
  ## Engine runs in separate thread to avoid blocking GUI
  initThreadMagics()

  while engineRunning.load(moRelaxed):
    let fen = engineInputChan.recv()
    if fen == "quit": break

    var board = initializeBoard(fen)

    var info: SearchInfo
    info.startTime = getMonoTime()
    # Adaptive time: 2s for early moves, up to 5s for complex positions
    info.allocatedTime = initDuration(milliseconds = 2500)
    info.depthLimit = 10  # Reduced depth for GUI mode (faster response)
    info.threadID = 0
    info.numThreads = 1

    let (bestMove, _) = iterativeDeepening(board, info)

    if bestMove != Move(0):
      engineOutputChan.send(bestMove.toAlgebraic())
    else:
      engineOutputChan.send("")

proc startEngineThread() =
  engineRunning.store(true, moRelaxed)
  engineInputChan.open()
  engineOutputChan.open()
  createThread(engineThread, engineWorker)

proc stopEngineThread() =
  engineRunning.store(false, moRelaxed)
  engineInputChan.send("quit")
  joinThread(engineThread)
  engineInputChan.close()
  engineOutputChan.close()

proc doEngineMove*() =
  if game.thinking: return

  game.thinking = true
  game.stopFlag.store(false)

  # Send current position to engine thread
  engineInputChan.send(game.board.toFen())

proc checkEngineResult() =
  if not game.thinking:
    # Auto move: trigger engine when it's Black's turn and auto mode is on
    if game.autoMove and not game.whiteToMove and game.board.sideToMove == Black:
      doEngineMove()
    return

  # Non-blocking check if engine has result
  let res = engineOutputChan.tryRecv()
  if res.dataAvailable:
    echo "MAIN: Received move from engine: '", res.msg, "'"
    if res.msg.len >= 4:
      echo "MAIN: Current board FEN: ", game.board.toFen()
      echo "MAIN: Current side to move: ", (if game.board.sideToMove == White: "White" else: "Black")
      echo "MAIN: Attempting to parse move: ", res.msg

      let bestMove = parseUCIMove(game.board, res.msg)

      if bestMove != Move(0):
        if game.board.makeMove(bestMove):
          game.moveHistory.add(res.msg)
          game.whiteToMove = game.board.sideToMove == White
          playPlacedSound()
    else:
      echo "MAIN: Received invalid move string (too short)"

    game.thinking = false
  else:
    # No result yet, engine still thinking
    discard


proc pixelToSquare(px, py: float64): int =
  let bx = px - BoardX.float64
  let by = py - BoardY.float64
  if bx < 0 or bx >= BoardSize.float64 or by < 0 or by >= BoardSize.float64:
    return -1
  let file = int(bx) div SquareSize
  # Screen Y increases downward, but we render rank 0 at bottom
  # Click bottom (large by) -> rank 0 (White)
  # Click top (small by) -> rank 7 (Black)
  let visualRank = int(by) div SquareSize  # 0 at top, 7 at bottom
  let rank = 7 - visualRank  # Flip: 0->7, 7->0
  result = rank * 8 + file

proc tryMakeMove(fromSq, toSq: int): bool =
  if fromSq < 0 or fromSq > 63 or toSq < 0 or toSq > 63:
    return false

  let piece = game.board.pieces[fromSq.Square]
  if piece == NoPiece: return false

  let isWhitePiece = piece in [WhitePawn, WhiteKnight, WhiteBishop, WhiteRook, WhiteQueen, WhiteKing]
  if isWhitePiece != game.whiteToMove: return false

  let uci = squareToUCI(fromSq) & squareToUCI(toSq)
  let move = parseUCIMove(game.board, uci)

  if move != Move(0):
    if game.board.makeMove(move):
      game.moveHistory.add(uci)
      game.whiteToMove = game.board.sideToMove == White
      playPlacedSound()
      return true

  return false


proc renderBoard() =
  let pieces = boardToUIPieces(game.board)

  for rank in 0..7:
    for file in 0..7:
      let sq = rank * 8 + file
      let x = BoardX + file * SquareSize
      # Flip Y so rank 0 (White) is at bottom, rank 7 (Black) at top
      let y = BoardY + (7 - rank) * SquareSize

      var c = if ((rank + file) mod 2) == 0: CLight else: CDark
      if sq == game.selectedSq:
        c = CSelect

      rect(x.float32, y.float32, SquareSize.float32, SquareSize.float32, c)

      let p = pieces[sq]
      if p != uiNone:
        let pieceX = x.float32
        let pieceY = y.float32
        let pieceSize = SquareSize.float32
        drawTexturedPiece(pieceX, pieceY, pieceSize, pieceTextures[p.ord])

  # Draw board coordinates - cache textures
  if font.isFontLoaded:
    let coordSize = 20
    let coordColor = color(0.4, 0.25, 0.1, 1.0)  # Brown text color
    
    # Cache coordinate labels once
    if not coordLabelsCached:
      for file in 0..7:
        let label = $chr(ord('a') + file)
        fileLabelTex[file] = renderTextToTexture(label, coordSize, coordSize, color(0, 0, 0, 0), coordColor)
      for rank in 0..7:
        let label = $chr(ord('1') + rank)
        rankLabelTex[rank] = renderTextToTexture(label, coordSize, coordSize, color(0, 0, 0, 0), coordColor)
      coordLabelsCached = true

    # Draw file labels (a-h) at bottom
    for file in 0..7:
      let x = BoardX + file * SquareSize + SquareSize div 2 - coordSize div 2
      let y = BoardY + BoardSize + 5
      if fileLabelTex[file].id != 0:
        drawTexture(fileLabelTex[file], x.float32, y.float32)

    # Draw rank labels (1-8) at left
    for rank in 0..7:
      let x = BoardX - coordSize - 5
      let y = BoardY + (7 - rank) * SquareSize + SquareSize div 2 - coordSize div 2
      if rankLabelTex[rank].id != 0:
        drawTexture(rankLabelTex[rank], x.float32, y.float32)

proc renderUI() =
  # Panel dimensions and spacing system
  let panelX = BoardX + BoardSize + 30
  let panelW = 260.0f
  let panelH = (ScreenHeight - 100).float32
  let panelY = 50.0f

  # Spacing constants
  let padX = 20.0f
  let padY = 16.0f
  let sectionGap = 24.0f

  # Panel background with border
  rect(panelX.float32, panelY, panelW, panelH, CPanel)

  # Top decorative bar
  rect(panelX.float32, panelY, panelW, 3.0f, CPanelBorder)

  var currentY = panelY + padY + 4.0f

  # Title area - cache texture
  if font.isFontLoaded:
    if not titleCached:
      let title = "Game Controls"
      font.size = 22.0
      font.paint.color = color(CTextDark.r, CTextDark.g, CTextDark.b, 1.0)
      let bounds = font.layoutBounds(title)
      titleTexCached = renderTextToTexture(title, bounds.x.int + 10, bounds.y.int + 5,
                                           color(CPanel.r, CPanel.g, CPanel.b, 1.0),
                                           color(CTextDark.r, CTextDark.g, CTextDark.b, 1.0))
      titleCached = true
    if titleTexCached.id != 0:
      let titleX = panelX.float32 + (panelW - titleTexCached.width.float32) / 2
      drawTexture(titleTexCached, titleX, currentY)

  currentY += 36.0f

  # Status section - cache texture to avoid recreating every frame
  if font.isFontLoaded:
    let statusText = if game.thinking: "Engine thinking..."
                     elif game.whiteToMove: "White to move"
                     else: "Black to move"
    # Only recreate texture when status changes
    if statusText != lastStatusText:
      lastStatusText = statusText
      font.size = 16.0
      let statusColor = if game.thinking: color(0.6, 0.4, 0.2, 1.0)
                        else: color(CTextDark.r, CTextDark.g, CTextDark.b, 1.0)
      statusTexCached = renderTextToTexture(statusText, 220, 28,
                                            color(CPanel.r, CPanel.g, CPanel.b, 1.0),
                                            statusColor)
    if statusTexCached.id != 0:
      drawTexture(statusTexCached, panelX.float32 + padX, currentY)

  currentY += 32.0f

  # Divider line
  rect(panelX.float32 + padX, currentY, panelW - padX * 2, 1.0f, CPanelBorder)
  currentY += sectionGap

  # Button 1: Engine Move
  let btnW = panelW - padX * 2
  let btnH = 44.0f
  let btnX = panelX.float32 + padX
  let btnHovered = mouseX >= btnX.float64 and mouseX <= (btnX + btnW).float64 and
                   mouseY >= currentY.float64 and mouseY <= (currentY + btnH).float64
  let btnPressed = btnHovered and mousePressed

  let btnColor = if btnPressed:
                   CButtonActive
                 elif btnHovered:
                   CButtonHover
                 else:
                   CButton

  # Button shadow (offset 2px)
  rect(btnX + 2.0f, currentY + 2.0f, btnW, btnH, (0.5f, 0.45f, 0.35f, 0.3f))
  # Button body
  rect(btnX, currentY, btnW, btnH, btnColor)

  if btn1Tex.id != 0:
    drawTexture(btn1Tex, btnX + (btnW - btn1Tex.width.float32) / 2, currentY + (btnH - btn1Tex.height.float32) / 2)

  if btnHovered and mouseReleased and not game.thinking:
    doEngineMove()

  currentY += btnH + 12.0f

  # Button 2: New Game
  let btn2Hovered = mouseX >= btnX.float64 and mouseX <= (btnX + btnW).float64 and
                    mouseY >= currentY.float64 and mouseY <= (currentY + btnH).float64
  let btn2Pressed = btn2Hovered and mousePressed

  let btn2Color = if btn2Pressed:
                    CButtonActive
                  elif btn2Hovered:
                    CButtonHover
                  else:
                    CButton

  # Button shadow
  rect(btnX + 2.0f, currentY + 2.0f, btnW, btnH, (0.5f, 0.45f, 0.35f, 0.3f))
  # Button body
  rect(btnX, currentY, btnW, btnH, btn2Color)

  if btn2Tex.id != 0:
    drawTexture(btn2Tex, btnX + (btnW - btn2Tex.width.float32) / 2, currentY + (btnH - btn2Tex.height.float32) / 2)

  if btn2Hovered and mouseReleased:
    game.board = initializeBoard()
    game.selectedSq = -1
    game.moveHistory = @[]
    game.whiteToMove = true
    game.autoMove = false
    # Reset caches
    lastMoveHistoryLen = 0
    moveHistoryTexCached.setLen(0)
    lastStatusText = ""
    # Reset Auto button texture
    let btnBg = color(CButton.r, CButton.g, CButton.b, 1.0)
    let btnTextColor = color(0.98, 0.96, 0.92, 1.0)
    btn3Tex = renderTextToTexture("Auto: OFF", 120, 36, btnBg, btnTextColor)

  currentY += btnH + 12.0f

  # Button 3: Auto Move Toggle
  let btn3Hovered = mouseX >= btnX.float64 and mouseX <= (btnX + btnW).float64 and
                    mouseY >= currentY.float64 and mouseY <= (currentY + btnH).float64
  let btn3Pressed = btn3Hovered and mousePressed

  let btn3Color = if game.autoMove:
                    (0.45f, 0.65f, 0.45f, 1.0f)  # Green when ON
                  elif btn3Pressed:
                    CButtonActive
                  elif btn3Hovered:
                    CButtonHover
                  else:
                    CButton

  # Button shadow
  rect(btnX + 2.0f, currentY + 2.0f, btnW, btnH, (0.5f, 0.45f, 0.35f, 0.3f))
  # Button body
  rect(btnX, currentY, btnW, btnH, btn3Color)

  # Update texture based on state
  if btn3Tex.id != 0:
    drawTexture(btn3Tex, btnX + (btnW - btn3Tex.width.float32) / 2, currentY + (btnH - btn3Tex.height.float32) / 2)

  if btn3Hovered and mouseReleased:
    game.autoMove = not game.autoMove
    # Recreate texture with new text
    let btnBg = if game.autoMove: color(0.45, 0.65, 0.45, 1.0) else: color(CButton.r, CButton.g, CButton.b, 1.0)
    let btnTextColor = color(0.98, 0.96, 0.92, 1.0)
    btn3Tex = renderTextToTexture(if game.autoMove: "Auto: ON" else: "Auto: OFF", 120, 36, btnBg, btnTextColor)

  currentY += btnH + sectionGap

  # Move history section
  rect(panelX.float32 + padX, currentY, panelW - padX * 2, 1.0f, CPanelBorder)
  currentY += 12.0f

  if font.isFontLoaded:
    # Cache history title
    if not historyTitleCached:
      let historyTitle = "Move History"
      historyTitleTexCached = renderTextToTexture(historyTitle, 120, 24,
                                                  color(CPanel.r, CPanel.g, CPanel.b, 1.0),
                                                  color(CTextDark.r, CTextDark.g, CTextDark.b, 1.0))
      historyTitleCached = true
    if historyTitleTexCached.id != 0 and game.moveHistory.len > 0:
      drawTexture(historyTitleTexCached, panelX.float32 + padX, currentY)

    currentY += 26.0f

    # Show last few moves - only update cache when history changes
    if game.moveHistory.len != lastMoveHistoryLen:
      lastMoveHistoryLen = game.moveHistory.len
      # Clear old cache and create new textures
      moveHistoryTexCached.setLen(0)
      let startIdx = max(0, game.moveHistory.len - 6)
      for i in startIdx ..< game.moveHistory.len:
        let moveNum = (i div 2) + 1
        let prefix = if i mod 2 == 0: $moveNum & ". " else: "    "
        let moveText = prefix & game.moveHistory[i]
        let moveTex = renderTextToTexture(moveText, 200, 22,
                                          color(CPanel.r, CPanel.g, CPanel.b, 1.0),
                                          color(0.45, 0.35, 0.25, 1.0))
        moveHistoryTexCached.add(moveTex)
    
    # Draw cached move textures
    var drawY = currentY
    for tex in moveHistoryTexCached:
      if tex.id != 0:
        drawTexture(tex, panelX.float32 + padX + 5.0f, drawY)
      drawY += 22.0f


when isMainModule:
  if not nglfw.init():
    echo "Failed to initialize GLFW"
    quit(1)

  let window = createWindow(ScreenWidth.cint, ScreenHeight.cint, "Gyatso Chess", nil, nil)
  if window == nil:
    echo "Failed to create window"
    nglfw.terminate()
    quit(1)

  window.makeContextCurrent()
  swapInterval(1)
  loadExtensions()

  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

  initGame()

  discard window.setKeyCallback(proc(w: Window, key, scancode, action, mods: int32) {.cdecl.} =
    if key == KEY_ESCAPE and action == PRESS:
      w.setWindowShouldClose(true)
    if key == KEY_F9 and action == PRESS and not game.thinking:
      doEngineMove()
  )

  discard window.setMouseButtonCallback(proc(w: Window, button, action, mods: int32) {.cdecl.} =
    if button == MOUSE_BUTTON_LEFT:
      if action == PRESS:
        mousePressed = true
      elif action == RELEASE:
        mouseReleased = true
        mousePressed = false
  )

  startEngineThread()

  const targetFrameTime = initDuration(milliseconds = 33)  # ~30 FPS - reduce CPU usage

  while not window.windowShouldClose:
    let frameStart = getMonoTime()
    
    checkEngineResult()

    mouseReleased = false
    nglfw.pollEvents()

    window.getCursorPos(mouseX.addr, mouseY.addr)

    if mouseReleased and not game.thinking:
      let sq = pixelToSquare(mouseX, mouseY)
      if sq >= 0:
        if game.selectedSq < 0:
          let piece = game.board.pieces[sq.Square]
          if piece != NoPiece:
            let isWhite = piece in [WhitePawn, WhiteKnight, WhiteBishop, WhiteRook, WhiteQueen, WhiteKing]
            if isWhite == game.whiteToMove:
              game.selectedSq = sq
        else:
          if tryMakeMove(game.selectedSq, sq):
            game.selectedSq = -1
          else:
            let piece = game.board.pieces[sq.Square]
            if piece != NoPiece:
              let isWhite = piece in [WhitePawn, WhiteKnight, WhiteBishop, WhiteRook, WhiteQueen, WhiteKing]
              if isWhite == game.whiteToMove:
                game.selectedSq = sq
              else:
                game.selectedSq = -1
            else:
              game.selectedSq = -1

    glClearColor(0.98f, 0.96f, 0.88f, 1.0f)
    glClear(GL_COLOR_BUFFER_BIT)

    renderBoard()
    renderUI()

    window.swapBuffers()
    
    # Frame rate limiting: sleep to maintain ~60 FPS
    let frameEnd = getMonoTime()
    let elapsed = frameEnd - frameStart
    if elapsed < targetFrameTime:
      let sleepTime = targetFrameTime - elapsed
      sleep(sleepTime.inMilliseconds.int)

  stopEngineThread()
  destroyWindow(window)
  nglfw.terminate()

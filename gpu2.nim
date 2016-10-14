import graphics, colors, mem2, sdl, utils, unsigned, math

type
  GPU = ref object
    surface: graphics.PSurface
    mem: Memory

    mode: GpuMode
    clock: int

  GpuMode = enum
    HBlank = 0, VBlank = 1, OamRead = 2, VramRead = 3

  LCDC = object
    displayEnabled: bool
    winTileMap: bool # False for 0x9800-0x9BFF, True for 0x9C00-0x9FFF.
    winDisplayEnabled: bool
    winBgTileData: bool # False for 0x8800-0x97FF, True for 0x8000-0x8FFF.
    bgTileMap: bool # False for 0x9800-0x9BFF, True for 0x9C00-0x9FFF.
    spriteSize: bool # (Obj Size). False for 8x8, True for 8*16
    spriteDisplayEnabled: bool
    bgDisplayEnabled: bool

proc newGPU*(mem: Memory): GPU =
  new result
  result.surface = newScreenSurface(640, 480)
  initDefaultFont(r"Hack-Regular.ttf", 12)
  result.surface.fillSurface(colWhite)

  result.mem = mem

proc getLCDC(gpu: GPU): LCDC =
  let ff40 = gpu.mem.read8(0xFF40)
  result.displayEnabled = (ff40 and (1 shl 7)) != 0
  result.winTileMap = (ff40 and (1 shl 6)) != 0
  result.winDisplayEnabled = (ff40 and (1 shl 5)) != 0
  result.winBgTileData = (ff40 and (1 shl 4)) != 0
  result.bgTileMap = (ff40 and (1 shl 3)) != 0
  result.spriteSize = (ff40 and (1 shl 2)) != 0
  result.spriteDisplayEnabled = (ff40 and (1 shl 1)) != 0
  result.bgDisplayEnabled = (ff40 and 1) != 0

proc getPaletteBg(gpu: GPU): array[4, colors.Color] =
  let ff47 = gpu.mem.read8(0xFF47)
  for i in 0 .. 3:
    let shade = (ff47 shr (i.uint8 * 2)) and 0b11
    case shade
    of 0: result[i] = colWhite
    of 1: result[i] = rgb(192, 192, 192)
    of 2: result[i] = rgb(96, 96, 96)
    of 3: result[i] = colBlack

proc drawMem*(gpu: GPU) =
  let lcdc = getLCDC(gpu)
  gpu.surface.drawText((510, 5), "BG: " & $lcdc.bgDisplayEnabled)
  gpu.surface.drawText((510, 20), "Sprite: " & $lcdc.spriteDisplayEnabled)
  gpu.surface.drawText((510, 35), "Win: " & $lcdc.winDisplayEnabled)
  gpu.surface.drawText((510, 50), "All: " & $lcdc.displayEnabled)

  for i in countup(0, 0x1FF, 2):
    let address = 0x9900'u16 + i.uint16
    let value = gpu.mem.read16(address)
    let pos = i
    #assert(value == 0, address.toHex())
    gpu.surface.drawText((400, 5 + (10*pos)), "0x" & address.toHex())
    gpu.surface.drawText((460, 5 + (10*pos)), "0x" & value.toHex())

proc renderLine(gpu: GPU) =
  let lcdc = getLCDC(gpu)
  if not lcdc.bgDisplayEnabled: return

  let mapOffset: uint16 =
    if lcdc.bgTileMap: 0x9C00
    else: 0x9800

  # Current line.
  let ly = gpu.mem.read8(0xFF44)

  #let xscroll = gpu.mem.read8()
  #let yscroll = gpu.mem.read8()
  #let ybase = yscroll + ly

  #let tileNumAddr = mapOffset or ((ybase and 0xF8) shl 2) or
  #                  ((xscroll and 0xF8) shr 3)

  # The address pointing to the current line of tile numbers.
  # Each tile number
  let tileNumAddr: uint16 = ly * 4

  #for i in 0 .. 160:
  #  let tileOffset = floor(i / 8).uint16
  #  let tileNum = gpu.mem.read8(mapOffset + tileNumAddr + tileOffset)

proc renderTile(gpu: GPU, tileNum: uint16, x, y: uint16) =
  let lcdc = getLCDC(gpu)
  let palette = getPaletteBg(gpu)

  let dataOffset: uint16 =
    if lcdc.winBgTileData: 0x8000
    else: 0x8800

  # TODO: 8800 tile numbers are signed!

  let tileDataAddr = dataOffset + (tileNum * 16)

  if tileNum == 16:
    assert(tileDataAddr == 0x8100, tileDataAddr.toHex())

  for line in 0'u8 .. 7'u8:
    let lineDataLower = gpu.mem.read8(tileDataAddr + (line*2).uint16)
    let lineDataHigher = gpu.mem.read8(tileDataAddr + (line*2).uint16 + 1)
    for tileX in 0'u8 .. 7'u8:
      let lower = (lineDataLower shr (7'u8 - tileX)) and 1
      let higher = (lineDataHigher shr (7'u8 - tileX)) and 1
      let colorNum = (higher shl 1) or lower
      gpu.surface[int(x + tileX), int(y + line)] = palette[colorNum]
  
proc renderSignedTile(gpu: GPU, tileNum: int16, x, y: uint16) =
  

  let dataOffset: int =
    if lcdc.winBgTileData: 0x8000
    else: 0x8800

  # TODO: 8800 tile numbers are signed!

  let tileDataAddr = dataOffset + (tileNum+128 * 16)
  #I have no idea what this line does. (This is Zion)
  if tileNum == 16:
    #echo "really bad"
    assert(tileDataAddr == 33024, cast[uint16](tileDataAddr).toHex())

  for line in 0 .. 7:
    let lineDataLower = (int16)gpu.mem.read8(cast[uint16](tileDataAddr + (line*2)))
    let lineDataHigher = (int16)gpu.mem.read8(cast[uint16](tileDataAddr + (line*2) + 1))
    for tileX in 0 .. 7:
      let lower = (lineDataLower shr (7 - tileX)) and 1
      let higher = (lineDataHigher shr (7 - tileX)) and 1
      let colorNum = (higher shl 1) or lower
      gpu.surface[int(cast[int16](x) + tileX), int(cast[int16](y) + line)] = palette[colorNum]

proc BitGetVal(inData, inBitPosition: int ): int =
  var lMsk = 1 shl inBitPosition
  if (inData and lMsk) == 1:
    return 1
  else: return 0

proc RenderTiles(gpu: GPU) =
  
  let lcdc = getLCDC(gpu)
  let palette = getPaletteBg(gpu)
  
  var tileData: uint16 = 0
  var backgroundMemory: uint16 = 0 
  var unsigned = true

  # where to draw the visual area and the window
  let scrollY: uint8 = gpu.mem.read8(0xFF42)
  let scrollX: uint8 = gpu.mem.read8(0xFF43)
  let windowY: uint8 = gpu.mem.read8(0xFF4A)
  let windowX: uint8 = gpu.mem.read8(0xFF4B) - 7

  var usingWindow = false

  # is the window enabled?
  if lcdc.winDisplayEnabled:
    #is the current scanline we're drawing 
    #within the windows Y pos?,
    if windowY <= gpu.mem.read8(0xFF44):
       usingWindow = true ;
  #which tile data are we using? 
  if lcdc.winBgTileData:
    tileData = 0x8000
  else:
    # IMPORTANT: This memory region uses signed 
    # bytes as tile identifiers
    tileData = 0x8800
    unsigned = false
  #which background mem?
  if usingWindow == false:
    if lcdc.bgTileMap:
      backgroundMemory = 0x9C00
    else:
      backgroundMemory = 0x9800
  else:
    # which window memory?
    if lcdc.winTileMap:
      backgroundMemory = 0x9C00
    else:
      backgroundMemory = 0x9800
  var yPos: uint8 = 0

  # yPos is used to calculate which of 32 vertical tiles the 
  # current scanline is drawing
  if usingWindow == false:
    yPos = scrollY + gpu.mem.read8(0xFF44)
  else:
    yPos = gpu.mem.read8(0xFF44) - windowY

  # which of the 8 vertical pixels of the current 
  # tile is the scanline on?
  var tileRow: uint16 = (yPos div 8)*32

  # time to start drawing the 160 horizontal pixels
  # for this scanline
  for pixel in 0'u8..160'u8:
    var xPos: uint8 = cast[uint8](pixel)+scrollX ;

    # translate the current x pos to window space if necessary
    if usingWindow:
       if pixel >= windowX:
           xPos = pixel - windowX

    # which of the 32 horizontal tiles does this xPos fall within?
    var tileCol: uint16 = xPos div 8
    var tileNum: int16

    #get the tile identity number. Remember it can be signed
    #or unsigned
    var tileAddrss: uint16 = backgroundMemory+tileRow+tileCol;
    if unsigned:
      tileNum = cast[int16](gpu.mem.read8(tileAddrss))
    else:
       tileNum = cast[int16](gpu.mem.read8(tileAddrss))

    # deduce where this tile identifier is in memory. Remember i 
    # shown this algorithm earlier
    var tileLocation: uint16 = tileData

    if unsigned:
      tileLocation += cast[uint16]((tileNum * 16))
    else:
      tileLocation += cast[uint16]((tileNum+ 128'i16) * 16)

    # find the correct vertical line we're on of the 
    # tile to get the tile data 
    # from in memory
    var line: uint8 = yPos mod 8
    line *= 2; # each vertical line takes up two bytes of memory
    var data1: uint8 = gpu.mem.read8(tileLocation + line)
    var data2: uint8 = gpu.mem.read8(tileLocation + line + 1)

    # pixel 0 in the tile is it 7 of data 1 and data2.
    # Pixel 1 is bit 6 etc..
    var colourBit: int = cast[int](xPos) mod 8
    colourBit -= 7
    colourBit *= -1

    # combine data 2 and data 1 to get the colour id for this pixel 
    # in the tile
    var colourNum: int = BitGetVal(cast[int](data2),colourBit)
    #colourNum <<= 1;
    colourNum = colourNum or BitGetVal(cast[int](data1),colourBit)

    # now we have the colour id get the actual 
    # colour from palette 0xFF47
    # COLOUR col = GetColour(colourNum, 0xFF47) ;
    # int red = 0;
    # int green = 0;
    # int blue = 0
    # // setup the RGB values
    # switch(col)
    # {
    #   case WHITE:	red = 255; green = 255 ; blue = 255; break ;
    #   case LIGHT_GRAY:red = 0xCC; green = 0xCC ; blue = 0xCC; break ;
    #   case DARK_GRAY:	red = 0x77; green = 0x77 ; blue = 0x77; break ;
    # }
    #
    # int finaly = ReadMemory(0xFF44) ;
    #
     #// safety check to make sure what im about 
     #// to set is int the 160x144 bounds
     #if ((finaly<0)||(finaly>143)||(pixel<0)||(pixel>159))
     #{
     #  continue ;
     #}

     #m_ScreenData[pixel][finaly][0] = red ;
     #m_ScreenData[pixel][finaly][1] = green ;
     #m_ScreenData[pixel][finaly][2] = blue ;
     #gpu.surface[int(cast[int16](x) + tileX), int(cast[int16](y) + line)] = palette[colorNum]
proc renderAll(gpu: GPU) =
  let lcdc = getLCDC(gpu)
  if not lcdc.bgDisplayEnabled: return

  assert(not lcdc.spriteSize)

  let mapOffset: uint16 =
    if lcdc.bgTileMap: 0x9C00
    else: 0x9800

  for y in countup(0, 256 - 8, 8):
    for x in countup(0, 256 - 8, 8):
      let tileNumAddr = (y.uint16 * 4) + (x.uint16 div 8)
      #This is where the fancy schmancy signed int stuff goes.
      let tileNum = gpu.mem.read8(mapOffset + tileNumAddr)
      #assert(lcdc.winBgTileData)
      if lcdc.winBgTileData == true:
        renderTile(gpu, tileNum, x.uint16, y.uint16)
      else:
        renderSignedTile(gpu, cast[int8](tileNum), x.uint16, y.uint16)


  let scrollY = gpu.mem.read8(0xFF42)
  let scrollX = gpu.mem.read8(0xFF43)
  gpu.surface.drawRect((scrollX.int, scrollY.int, 160, 144), colRed)

proc next*(gpu: GPU, clock: int): bool =

  gpu.clock.inc clock

  case gpu.mode
  of OamRead:
    if gpu.clock >= 80:
      gpu.mode = VRAMRead
      gpu.clock = 0
  of VramRead:
    if gpu.clock >= 172:
      gpu.mode = HBlank
      gpu.clock = 0

      # Render ScanLine
      gpu.renderLine()
  of HBlank:
    if gpu.clock >= 204:
      gpu.clock = 0

      let ly = gpu.mem.read8(0xFF44)

      #echo("HBlank line: ", gpu.line)
      if ly == 144:
        # We reached the bottom edge of the screen (screen is 144 pixels in height.)
        gpu.mode = VBlank
        gpu.mem.requestInterrupt(0)

        renderAll(gpu)
        #drawMem(gpu)
        sdl.updateRect(gpu.surface.s, 0, 0, 640, 480)
      else:
        gpu.mode = OamRead

      gpu.mem.write8(0xFF44, ly+1)
  of VBlank:
    if gpu.clock >= 456:
      gpu.clock = 0

      let ly = gpu.mem.read8(0xFF44)

      if ly == 153:
        gpu.mode = OAMRead
        gpu.mem.write8(0xFF44, 0)
      else:
        gpu.mem.write8(0xFF44, ly+1)

  var event: TEvent
  if pollEvent(addr(event)) == 1:
    case event.kind:
    of sdl.QUITEV:
      quit(QuitSuccess)
    of sdl.KEYDOWN:
      var evk = sdl.evKeyboard(addr event)
      if evk.keysym.sym == sdl.K_SPACE:
        return true
      else:
        echo(evk.keysym.sym)
    else:
      nil

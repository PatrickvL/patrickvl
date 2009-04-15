(*
    This file is part of Dxbx - a XBox emulator written in Delphi (ported over from cxbx)
    Copyright (C) 2007 Shadow_tj and other members of the development team.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)
unit uEmuD3D8;

{$INCLUDE Dxbx.inc}

interface

uses
  // Delphi
  Windows,
  Messages,
  SysUtils,
  Classes, // TStringList
  Math,
  MMSystem, // timeBeginPeriod
  // Directx
  D3DX8,
  Direct3D,
  Direct3D8,
  DirectDraw,
  // Dxbx
  XboxKrnl,
  uConvert,
  uEmuD3D8Types,
  uDxbxUtils,
  uDxbxKrnlUtils,
  uEmuDInput,
  uPushBuffer,
  uVertexShader,
  uEmu,
  uEmuKrnl,
  uLog,
  uTypes,
  uXbe,
  uEmuAlloc,
  uXbVideo,
  uEmuShared,
  uEmuFS,
  uEmuXapi,
  uVertexBuffer,
  uState;

type
  PIDirect3DDevice8 = ^IDirect3DDevice8;

  // information passed to the create device proxy thread
  EmuD3D8CreateDeviceProxyData = packed record
    Adapter: UINT;
    DeviceType: D3DDEVTYPE;
    hFocusWindow: HWND;
    BehaviorFlags: DWORD;
    pPresentationParameters: PX_D3DPRESENT_PARAMETERS;
    ppReturnedDeviceInterface: PIDirect3DDevice8;
    bReady: Bool;
    case Integer of
      0: (hRet: HRESULT);
      1: (bCreate: bool); // False: release
  end;

var
  g_EmuCDPD: EmuD3D8CreateDeviceProxyData;

function iif(AValue: Boolean; const ATrue: TD3DDevType; const AFalse: TD3DDevType): TD3DDevType; overload;

procedure XTL_EmuD3DInit(XbeHeader: pXBE_HEADER; XbeHeaderSize: UInt32); stdcall; // forward
function XTL_EmuIDirect3D8_CreateDevice(Adapter: UINT; DeviceType: D3DDEVTYPE;
  hFocusWindow: HWND; BehaviorFlags: DWORD;
  pPresentationParameters: PX_D3DPRESENT_PARAMETERS;
  ppReturnedDeviceInterface: PIDirect3DDevice8): HRESULT; stdcall; // forward

function XTL_EmuIDirect3DDevice8_SetVertexData2f(aRegister: Integer;
  a: FLOAT; b: FLOAT): HRESULT; stdcall;
function XTL_EmuIDirect3DDevice8_SetVertexData4f(aRegister: Integer;
  a, b, c, d: FLOAT): HRESULT; stdcall; // forward
procedure XTL_EmuIDirect3DDevice8_GetVertexShader(var aHandle: DWORD); stdcall; // forward

function EmuRenderWindow(lpVoid: Pointer): DWord; // forward
function EmuMsgProc(hWnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall; // forward
function EmuUpdateTickCount(LPVOID: Pointer): DWord; //stdcall;
function EmuCreateDeviceProxy(LPVOID: Pointer): DWord; //stdcall;

implementation

uses
  // Dxbx
  uDxbxKrnl
  , uXboxLibraryUtils; // Should not be here, but needed for CxbxKrnlRegisterThread

var
  // Global(s)
  g_pD3DDevice8: IDIRECT3DDEVICE8; // Direct3D8 Device
  g_pDDSPrimary: IDIRECTDRAWSURFACE7; // DirectDraw7 Primary Surface
  g_pDDSOverlay7: IDIRECTDRAWSURFACE7; // DirectDraw7 Overlay Surface
  g_pDDClipper: IDIRECTDRAWCLIPPER; // DirectDraw7 Clipper
  g_CurrentVertexShader: DWord = 0;
  g_bFakePixelShaderLoaded: Boolean = False;
  g_bIsFauxFullscreen: Boolean = False;

  // Static Variable(s)
  g_ddguid: TGUID; // DirectDraw driver GUID
  g_hMonitor: HMONITOR; // Handle to DirectDraw monitor
  g_pD3D8: IDIRECT3D8 {or LPDIRECT3D8 ?}; // Direct3D8
  g_bSupportsYUY2: BOOL = FALSE; // Does device support YUY2 overlays?
  g_pDD7: IDirectDraw7 {or LPDIRECTDRAW7 ?}; // DirectDraw7
  g_dwOverlayW: DWORD = 640; // Cached Overlay Width
  g_dwOverlayH: DWORD = 480; // Cached Overlay Height
  g_dwOverlayP: DWORD = 640; // Cached Overlay Pitch
  g_XbeHeader: PXBE_HEADER; // XbeHeader
  g_XbeHeaderSize: DWord = 0; // XbeHeaderSize
  g_D3DCaps: D3DCAPS8; // Direct3D8 Caps
  g_hBgBrush: HBrush = 0; // Background Brush
  g_bRenderWindowActive: bool = False; // volatile?
  g_XBVideo: XBVideo;
  g_pVBCallback: D3DVBLANKCALLBACK = nil; // Vertical-Blank callback routine

  // wireframe toggle
  g_iWireframe: Integer = 0;

  // resource caching for _Register
  pCache: array[0..15 - 1] of X_D3DResource; // = {0};

  // current active index buffer
  g_pIndexBuffer: PX_D3DIndexBuffer = NULL; // current active index buffer
  g_dwBaseVertexIndex: DWORD = 0; // current active index buffer base index

  // current active vertex stream
  g_pVertexBuffer: PX_D3DVertexBuffer = nil; // current active vertex buffer
  g_pDummyBuffer: IDirect3DVertexBuffer8 = nil; // Dummy buffer, used to set unused stream sources with

  // current vertical blank information
  g_VBData: D3DVBLANKDATA;
  g_VBLastSwap: DWORD = 0;

  // cached Direct3D state variable(s)
  g_pCachedRenderTarget: PX_D3DSurface = nil;
  g_pCachedZStencilSurface: PX_D3DSurface = nil;
  g_YuvSurface: PX_D3DSurface = nil;
  g_fYuvEnabled: BOOL = FALSE;
  g_dwVertexShaderUsage: DWord = 0;
  g_VertexShaderSlots: array[0..136 - 1] of DWORD;

  // cached palette pointer
  pCurrentPalette: PVOID;

  g_VertexShaderConstantMode: X_VERTEXSHADERCONSTANTMODE = X_VSCM_192;

  // cached Direct3D tiles
  EmuD3DTileCache: array[0..8 - 1] of X_D3DTILE;

  // cached active texture
  EmuD3DActiveTexture: array[0..4 - 1] of PX_D3DResource; // = {0,0,0,0};

function iif(AValue: Boolean; const ATrue: TD3DDevType; const AFalse: TD3DDevType): TD3DDevType;
// Branch:martin  Revision:39  Translator:Shadow_Tj Done:100
begin
  if AValue then
    Result := ATrue
  else
    Result := AFalse;
end;

procedure XTL_EmuD3DInit(XbeHeader: pXBE_HEADER; XbeHeaderSize: UInt32); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  dwThreadId: DWORD;
  hThread: THandle;
  hDupHandle: THandle;
  DevType: D3DDEVTYPE;
  PresParam: X_D3DPRESENT_PARAMETERS;
begin
  g_EmuShared.GetXBVideo({var}g_XBVideo);

  if g_XBVideo.GetFullscreen() then
    CxbxKrnl_hEmuParent := 0;

  // cache XbeHeader and size of XbeHeader
  g_XbeHeader := XbeHeader;
  g_XbeHeaderSize := XbeHeaderSize;

  // create timing thread
  begin
    hThread := BeginThread(nil, 0, @EmuUpdateTickCount, nil, 0, {var} dwThreadId);

    // we must duplicate this handle in order to retain Suspend/Resume thread rights from a remote thread
    begin
      hDupHandle := 0;

      DuplicateHandle(GetCurrentProcess(), hThread, GetCurrentProcess(), @hDupHandle, 0, False, DUPLICATE_SAME_ACCESS);

      CxbxKrnlRegisterThread(hDupHandle);
    end;
  end;

  // create the create device proxy thread
  begin
    BeginThread(nil, 0, @EmuCreateDeviceProxy, nil, 0, {var} dwThreadId);
  end;

  // create window message processing thread
  begin
    g_bRenderWindowActive := False;

    BeginThread(nil, 0, @EmuRenderWindow, nil, 0, {var} dwThreadId);

    while not g_bRenderWindowActive do
      Sleep(10); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?

    Sleep(50);
  end;

  // create Direct3D8 and retrieve caps
  begin
    //  using namespace XTL;

    // xbox Direct3DCreate8 returns '1' always, so we need our own ptr
    g_pD3D8 := Direct3DCreate8(D3D_SDK_VERSION);
    if g_pD3D8 = nil then
      CxbxKrnlCleanup('Could not initialize Direct3D8!');

    DevType := iif(g_XBVideo.GetDirect3DDevice() = 0, D3DDEVTYPE_HAL, D3DDEVTYPE_REF);
    g_pD3D8.GetDeviceCaps(g_XBVideo.GetDisplayAdapter(), DevType, {out} g_D3DCaps);
  end;

  SetFocus(g_hEmuWindow);

  // create default device
  begin
    ZeroMemory(@PresParam, SizeOf(PresParam));
    PresParam.BackBufferWidth := 640;
    PresParam.BackBufferHeight := 480;
    PresParam.BackBufferFormat := X_D3DFMT_A8R8G8B8; //6; (* X_D3DFMT_A8R8G8B8 *)
    PresParam.BackBufferCount := 1;
    PresParam.EnableAutoDepthStencil := True;
    PresParam.AutoDepthStencilFormat := X_D3DFMT_D24S8; //$2A; (* X_D3DFMT_D24S8 *)
    PresParam.SwapEffect := D3DSWAPEFFECT_DISCARD;

    EmuSwapFS(fsXbox);
    XTL_EmuIDirect3D8_CreateDevice(
      0,
      D3DDEVTYPE_HAL,
      {ignored hFocusWindow=}0,
      {ignored BehaviorFlags=}D3DCREATE_HARDWARE_VERTEXPROCESSING, // = $00000040
      @PresParam,
      @g_pD3DDevice8);
    EmuSwapFS(fsWindows);
  end;
end; // XTL_EmuD3DInit

// cleanup Direct3D

procedure XTL_EmuD3DCleanup; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  XTL_EmuDInputCleanup;
end;

// enumeration procedure for locating display device GUIDs

function EmuEnumDisplayDevices(lpGUID: PGUID; lpDriverDescription: LPSTR;
  lpDriverName: LPSTR; lpContext: LPDWORD; hm: HMONITOR): BOOL; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
{$WRITEABLECONST ON}
const
  dwEnumCount: DWORD = 0;
{$WRITEABLECONST OFF}
begin
  Inc(dwEnumCount);
  if (dwEnumCount = (g_XBVideo.GetDisplayAdapter() + 1)) then
  begin
    g_hMonitor := hm;
    dwEnumCount := 0;
    if Assigned(lpGUID) then
      memcpy(@g_ddguid, lpGUID, SizeOf(TGUID))
    else
      memset(@g_ddguid, 0, SizeOf(TGUID));

    Result := False;
    Exit;
  end;

  Result := TRUE;
end;

// window message processing thread

function EmuRenderWindow(lpVoid: Pointer): DWord;
// Branch:martin  Revision:39  Done:80 Translator:Shadow_Tj
const
  DXBX_RENDER_CLASS = 'DxbxRender';
var
  msg: TMsg;
  AsciiTitle: string;
  hDxbxDLL: HMODULE;
  logBrush: TLogBrush;
  wc: WNDCLASSEX;
  CertAddr: IntPtr; //uint32
  XbeCert: PXbe_Certificate;
  dwStyle: DWORD;
  nTitleHeight: Integer;
  nBorderWidth: Integer;
  nBorderHeight: Integer;
  x, y, nWidth, nHeight: Integer;
  hwndParent: HWND;
  lPrintfOn: bool;
begin
  // register window class
  begin
    hDxbxDLL := MainInstance;

    logBrush.lbStyle := BS_SOLID;
    logBrush.lbColor := RGB(0, 0, 0);
    logBrush.lbHatch := 0;

    g_hBgBrush := CreateBrushIndirect(logBrush);

    wc.cbSize := SizeOf(WNDCLASSEX);
    wc.style := CS_CLASSDC;
    wc.lpfnWndProc := @EmuMsgProc;
    wc.cbClsExtra := 0;
    wc.cbWndExtra := 0;
    wc.hInstance := GetModuleHandle(nil);
    wc.hIcon := LoadIcon(hDxbxDll, MAKEINTRESOURCE({IDI_CXBX=}101));
    wc.hCursor := LoadCursor(0, IDC_ARROW);
    wc.hbrBackground := g_hBgBrush;
    wc.lpszMenuName := '';
    wc.lpszClassName := DXBX_RENDER_CLASS;
    wc.hIconSm := 0;

    {Ignore ATOM:}RegisterClassEx(wc);
  end;

  // retrieve Xbe title (if possible)
  begin
    AsciiTitle := 'Unknown';

    CertAddr := g_XbeHeader.dwCertificateAddr - g_XbeHeader.dwBaseAddr;

    if CertAddr + $0C + 40 < g_XbeHeaderSize then
    begin
      IntPtr(XbeCert) := IntPtr(g_XbeHeader) + CertAddr;
      // SetLocaleInfo(LC_ALL, 'English'); // Not neccesary, Delphi has this by default
      AsciiTitle := XbeCert.wszTitleName; // No wcstombs needed, Delphi does this automatically
    end;

    AsciiTitle := 'Dxbx: Emulating ' + AsciiTitle;
  end;

  // create the window
  begin
    dwStyle := iif(g_XBVideo.GetFullscreen() or (CxbxKrnl_hEmuParent = 0), WS_OVERLAPPEDWINDOW, WS_CHILD);

    nTitleHeight := GetSystemMetrics(SM_CYCAPTION);
    nBorderWidth := GetSystemMetrics(SM_CXSIZEFRAME);
    nBorderHeight := GetSystemMetrics(SM_CYSIZEFRAME);

    x := 100;
    y := 100;
    nWidth := 640;
    nHeight := 480;

    Inc(nWidth, nBorderWidth * 2);
    Inc(nHeight, (nBorderHeight * 2) + nTitleHeight);

    sscanf(g_XBVideo.GetVideoResolution(), '%d x %d', [@nWidth, @nHeight]);

    if g_XBVideo.GetFullscreen() then
    begin
      x := 0;
      y := 0;
      nWidth := 0;
      nHeight := 0;
      dwStyle := WS_POPUP;
    end;

    if g_XBVideo.GetFullscreen() then
      hwndParent := GetDesktopWindow()
    else
      hwndParent := CxbxKrnl_hEmuParent;

    g_hEmuWindow := CreateWindow(
      DXBX_RENDER_CLASS,
      PChar(AsciiTitle),
      dwStyle,
      x,
      y,
      nWidth,
      nHeight,
      hwndParent,
      HMENU(0),
      GetModuleHandle(nil),
      nil
      );
  end;

  ShowWindow(g_hEmuWindow, iif((CxbxKrnl_hEmuParent = 0) or g_XBVideo.GetFullscreen, SW_SHOWDEFAULT, SW_SHOWMAXIMIZED));
  UpdateWindow(g_hEmuWindow);
  if (not g_XBVideo.GetFullscreen) and (CxbxKrnl_hEmuParent <> 0) then
    SetFocus(CxbxKrnl_hEmuParent);

  // initialize direct input
  if not XTL_EmuDInputInit() then
    CxbxKrnlCleanup('Could not initialize DirectInput!');

  DbgPrintf('EmuD3D8: Message-Pump thread is running.');

  SetFocus(g_hEmuWindow);

  { TODO: Need to be translated to delphi }
  (*
  DbgConsole *dbgConsole := new DbgConsole();
  *)

  // message processing loop
  begin
    ZeroMemory(@msg, SizeOf(msg));

    lPrintfOn := g_bPrintfOn;

    while msg.message <> WM_QUIT do
    begin
      if PeekMessage({var}msg, 0, 0, 0, PM_REMOVE) then
      begin
        g_bRenderWindowActive := True;
        TranslateMessage(msg);
        DispatchMessage(msg);
      end
      else
      begin
        Sleep(10); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?

        // if we've just switched back to display off, clear buffer & display prompt
        if not g_bPrintfOn and lPrintfOn then
          { TODO: Need to be translated to delphi }
          ; // dbgConsole.Reset();

        lPrintfOn := g_bPrintfOn;

        (*dbgConsole.Process();
        *)
      end;
    end;

    g_bRenderWindowActive := False;

//        delete dbgConsole;

    CxbxKrnlCleanup('');
  end;

  Result := 0;
end;

// simple helper function

procedure ToggleFauxFullscreen(hWnd: HWND);
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
{$J+}
const
  lRestore: LongInt = 0;
  lRestoreEx: LongInt = 0;
  lRect: TRect = ();
{$J-}
begin
  if (g_XBVideo.GetFullscreen()) then
    Exit;

  lRestore := 0;
  lRestoreEx := 0;

  lRect.Left := 0;
  lRect.Top := 0;
  lRect.Right := 0;
  lRect.Bottom := 0;

  if (not g_bIsFauxFullscreen) then
  begin
    if (CxbxKrnl_hEmuParent <> 0) then
    begin
      SetParent(hWnd, 0);
    end
    else
    begin
      lRestore := GetWindowLong(hWnd, GWL_STYLE);
      lRestoreEx := GetWindowLong(hWnd, GWL_EXSTYLE);
      GetWindowRect(hWnd, {var} lRect);
    end;

    SetWindowLong(hWnd, GWL_STYLE, WS_POPUP);
    ShowWindow(hWnd, SW_MAXIMIZE);
    SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOSIZE or SWP_NOMOVE);
  end
  else
  begin
    if CxbxKrnl_hEmuParent <> 0 then
    begin
      SetParent(hWnd, CxbxKrnl_hEmuParent);
      SetWindowLong(hWnd, GWL_STYLE, WS_CHILD);
      ShowWindow(hWnd, SW_MAXIMIZE);
      SetFocus(CxbxKrnl_hEmuParent);
    end
    else
    begin
      SetWindowLong(hWnd, GWL_STYLE, lRestore);
      SetWindowLong(hWnd, GWL_EXSTYLE, lRestoreEx);
      ShowWindow(hWnd, SW_RESTORE);
      SetWindowPos(hWnd, HWND_NOTOPMOST, lRect.left, lRect.top, lRect.right - lRect.left, lRect.bottom - lRect.top, 0);
      SetFocus(hWnd);
    end;
  end;

  g_bIsFauxFullscreen := not g_bIsFauxFullscreen;
end;

// rendering window message procedure

function EmuMsgProc(hWnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
var
  bAutoPaused: Boolean;
begin
  bAutoPaused := False;

  Result := 0;
  case (msg) of
    WM_DESTROY:
      begin
        DeleteObject(g_hBgBrush);
        PostQuitMessage(0);
        Result := 0;
      end;

    WM_SYSKEYDOWN:
      begin
        if (wParam = VK_RETURN) then
        begin
          ToggleFauxFullscreen(hWnd);
        end
        else if (wParam = VK_F4) then
        begin
          PostMessage(hWnd, WM_CLOSE, 0, 0);
        end;
      end;

    WM_KEYDOWN:
      begin
        // disable fullscreen if we are set to faux mode, and faux fullscreen is active
        if (wParam = VK_ESCAPE) then
        begin
          if (g_XBVideo.GetFullscreen()) then
          begin
            SendMessage(hWnd, WM_CLOSE, 0, 0);
          end
          else if (g_bIsFauxFullscreen) then
          begin
            ToggleFauxFullscreen(hWnd);
          end;
        end
        else if (wParam = VK_F8) then
        begin
          g_bPrintfOn := not g_bPrintfOn;
        end
        else if (wParam = VK_F9) then
        begin
          XTL_g_bBrkPush := True;
        end
        else if (wParam = VK_F10) then
        begin
          ToggleFauxFullscreen(hWnd);
        end
        else if (wParam = VK_F11) then
        begin
          Inc(g_iWireframe);
          if g_iWireframe = 2 then
            g_iWireframe := 0;
        end
        else if (wParam = VK_F12) then
        begin
          XTL_g_bStepPush := not XTL_g_bStepPush;
        end;
      end;

    WM_SIZE:
      begin
        case (wParam) of
          SIZE_RESTORED,
            SIZE_MAXIMIZED:
            begin
              if (bAutoPaused) then
              begin
                bAutoPaused := False;
                CxbxKrnlResume();
              end;
            end;

          SIZE_MINIMIZED:
            begin
              if (g_XBVideo.GetFullscreen()) then
                CxbxKrnlCleanup('0');

              if (not g_bEmuSuspended) then
              begin
                bAutoPaused := True;
                CxbxKrnlSuspend();
              end;
            end;
        end;
      end;

    WM_CLOSE: DestroyWindow(hWnd);

    WM_SETFOCUS:
      begin
        if (CxbxKrnl_hEmuParent <> 0) then
        begin
          SetFocus(CxbxKrnl_hEmuParent);
        end;
      end;

    WM_SETCURSOR:
      begin
        if (g_XBVideo.GetFullscreen() or g_bIsFauxFullscreen) then
        begin
          SetCursor(0);
          Result := 0;
        end;

        Result := DefWindowProc(hWnd, msg, wParam, lParam);
      end;
  else
    Result := DefWindowProc(hWnd, msg, wParam, lParam);
  end;
end;

function EmuUpdateTickCount(LPVOID: Pointer): DWord;
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
var
  curvb: Integer;
  v: Integer;
  hDevice: THandle;
  dwLatency: DWORD;
  pFeedback: PXINPUT_FEEDBACK;
begin
  // since callbacks come from here
  EmuGenerateFS(CxbxKrnl_TLS, CxbxKrnl_TLSData);

  DbgPrintf('EmuD3D8: Timing thread is running.');

  timeBeginPeriod(0);

  // current vertical blank count
  while True do
  begin
    xboxkrnl_KeTickCount := timeGetTime();
    Sleep(1); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?

    // Poll input
    begin
      for v := 0 to XINPUT_SETSTATE_SLOTS - 1 do
      begin
        hDevice := g_pXInputSetStateStatus[v].hDevice;

        if hDevice = 0 then
          Continue;

        dwLatency := g_pXInputSetStateStatus[v].dwLatency + 1;
        g_pXInputSetStateStatus[v].dwLatency := dwLatency;

        if dwLatency < XINPUT_SETSTATE_LATENCY then
          Continue;

        g_pXInputSetStateStatus[v].dwLatency := 0;

        pFeedback := PXINPUT_FEEDBACK(g_pXInputSetStateStatus[v].pFeedback);
        if pFeedback = nil then
          Continue;

        // Only update slot if it has not already been updated
        if pFeedback.Header.dwStatus <> ERROR_SUCCESS then
        begin
          if pFeedback.Header.hEvent <> 0 then
            SetEvent(pFeedback.Header.hEvent);

          pFeedback.Header.dwStatus := ERROR_SUCCESS;
        end;
      end;
    end;

    // trigger vblank callback
    begin
      g_VBData.VBlank := g_VBData.VBlank + 1;

      if Assigned(g_pVBCallback) then
      begin
        EmuSwapFS(fsXbox);
        g_pVBCallback(@g_VBData);
        EmuSwapFS(fsWindows);
      end;

      g_VBData.Swap := 0;
    end;

  end; // while

  timeEndPeriod(0);
end;

// thread dedicated to create devices

function EmuCreateDeviceProxy(LPVOID: Pointer): DWord;
// Branch:martin  Revision:42  Done:95 Translator:Shadow_Tj
type
  PArrayOfDWORD = ^TArrayOfDWORD;
  TArrayOfDWORD = array[0..(MaxInt shr 2) - 1] of DWORD;
var
  D3DDisplayMode: TD3DDisplayMode; // X_D3DDISPLAYMODE; // Dxbx TODO : What type should we use?
  szBackBufferFormat: array[0..16 - 1] of Char;
  hRet: HRESULT;
  dwCodes: DWord;
  lpCodes: PDWORD;
  v: Dword;
  ddsd2: DDSURFACEDESC2;
  Streams: Integer;
  TmpEmuSurface8: IDirect3DSurface8;
begin
  DbgPrintf('EmuD3D8: CreateDevice proxy thread is running.');

  while True do
  begin
    if not g_EmuCDPD.bReady then
    begin
      Sleep(10); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?
      Continue;
    end;

    // if we have been signalled, create the device with cached parameters
    DbgPrintf('EmuD3D8: CreateDevice proxy thread received request.');

    if (g_EmuCDPD.bCreate) then
    begin
      // only one device should be created at once
      // Cxbx TODO: ensure all surfaces are somehow cleaned up?
      if Assigned(g_pD3DDevice8) then
      begin
        DbgPrintf('EmuD3D8: CreateDevice proxy thread releasing old Device.');

        g_pD3DDevice8.EndScene();

        while (g_pD3DDevice8._Release() <> 0) do
          ;
        // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
        Pointer(g_pD3DDevice8) := nil;
      end;

      if Assigned(PX_D3DPRESENT_PARAMETERS(g_EmuCDPD.pPresentationParameters).BufferSurfaces[0]) then
        EmuWarning('BufferSurfaces[0]: 0x%.08X', [Pointer(PX_D3DPRESENT_PARAMETERS(g_EmuCDPD.pPresentationParameters).BufferSurfaces[0])]);

      if Assigned(PX_D3DPRESENT_PARAMETERS(g_EmuCDPD.pPresentationParameters).DepthStencilSurface) then
        EmuWarning('DepthStencilSurface: 0x%.08X', [Pointer(PX_D3DPRESENT_PARAMETERS(g_EmuCDPD.pPresentationParameters).DepthStencilSurface)]);

      // make adjustments to parameters to make sense with windows Direct3D
      begin
        g_EmuCDPD.DeviceType := iif(g_XBVideo.GetDirect3DDevice() = 0, D3DDEVTYPE_HAL, D3DDEVTYPE_REF);
        g_EmuCDPD.Adapter := g_XBVideo.GetDisplayAdapter();

        g_EmuCDPD.pPresentationParameters.Windowed := not g_XBVideo.GetFullscreen();

        if (g_XBVideo.GetVSync()) then
          g_EmuCDPD.pPresentationParameters.SwapEffect := D3DSWAPEFFECT_COPY_VSYNC;

        // Note: Instead of the hFocusWindow argument, we use the global g_hEmuWindow here:
        g_EmuCDPD.hFocusWindow := g_hEmuWindow;

        TD3DFormat(g_EmuCDPD.pPresentationParameters.BackBufferFormat) := EmuXB2PC_D3DFormat(g_EmuCDPD.pPresentationParameters.BackBufferFormat);
        TD3DFormat(g_EmuCDPD.pPresentationParameters.AutoDepthStencilFormat) := EmuXB2PC_D3DFormat(g_EmuCDPD.pPresentationParameters.AutoDepthStencilFormat);

        if (not g_XBVideo.GetVSync() and ((g_D3DCaps.PresentationIntervals and D3DPRESENT_INTERVAL_IMMEDIATE) > 0) and g_XBVideo.GetFullscreen()) then
          g_EmuCDPD.pPresentationParameters.FullScreen_PresentationInterval := D3DPRESENT_INTERVAL_IMMEDIATE
        else
        begin
          if ((g_D3DCaps.PresentationIntervals and D3DPRESENT_INTERVAL_ONE) > 0) and g_XBVideo.GetFullscreen() then
            g_EmuCDPD.pPresentationParameters.FullScreen_PresentationInterval := D3DPRESENT_INTERVAL_ONE
          else
            g_EmuCDPD.pPresentationParameters.FullScreen_PresentationInterval := D3DPRESENT_INTERVAL_DEFAULT;
        end;

        // Cxbx TODO: Support Xbox extensions if possible
        if (g_EmuCDPD.pPresentationParameters.MultiSampleType <> D3DMULTISAMPLE_NONE) then
        begin
          EmuWarning('MultiSampleType 0x%.08X is not supported!', [Ord(g_EmuCDPD.pPresentationParameters.MultiSampleType)]);

          g_EmuCDPD.pPresentationParameters.MultiSampleType := D3DMULTISAMPLE_NONE;

          // Cxbx TODO: Check card for multisampling abilities
          // if (g_EmuCDPD.pPresentationParameters.MultiSampleType = $00001121) then
          //   g_EmuCDPD.pPresentationParameters.MultiSampleType := D3DMULTISAMPLE_2_SAMPLES
          // else
          //   CxbxKrnlCleanup('Unknown MultiSampleType (0x%.08X)', [g_EmuCDPD.pPresentationParameters.MultiSampleType]);
        end;

        g_EmuCDPD.pPresentationParameters.Flags := D3DPRESENTFLAG_LOCKABLE_BACKBUFFER;

        // retrieve resolution from configuration
        if (g_EmuCDPD.pPresentationParameters.Windowed) then
        begin
          sscanf(g_XBVideo.GetVideoResolution(), '%d x %d', [@(g_EmuCDPD.pPresentationParameters.BackBufferWidth), @(g_EmuCDPD.pPresentationParameters.BackBufferHeight)]);

          g_pD3D8.GetAdapterDisplayMode(g_XBVideo.GetDisplayAdapter(), {out} D3DDisplayMode);

          g_EmuCDPD.pPresentationParameters.BackBufferFormat := X_D3DFORMAT(D3DDisplayMode.Format);
          g_EmuCDPD.pPresentationParameters.FullScreen_RefreshRateInHz := 0;
        end
        else
        begin
          sscanf(g_XBVideo.GetVideoResolution(), '%d x %d %*dbit %s (%d hz)', [
            @(g_EmuCDPD.pPresentationParameters.BackBufferWidth),
              @(g_EmuCDPD.pPresentationParameters.BackBufferHeight),
              @(szBackBufferFormat[0]),
              @(g_EmuCDPD.pPresentationParameters.FullScreen_RefreshRateInHz)]);

          if (StrComp(szBackBufferFormat, 'x1r5g5b5') = 0) then
            g_EmuCDPD.pPresentationParameters.BackBufferFormat := X_D3DFORMAT(D3DFMT_X1R5G5B5)
          else if (StrComp(szBackBufferFormat, 'r5g6r5') = 0) then
            g_EmuCDPD.pPresentationParameters.BackBufferFormat := X_D3DFORMAT(D3DFMT_R5G6B5)
          else if (StrComp(szBackBufferFormat, 'x8r8g8b8') = 0) then
            g_EmuCDPD.pPresentationParameters.BackBufferFormat := X_D3DFORMAT(D3DFMT_X8R8G8B8)
          else if (StrComp(szBackBufferFormat, 'a8r8g8b8') = 0) then
            g_EmuCDPD.pPresentationParameters.BackBufferFormat := X_D3DFORMAT(D3DFMT_A8R8G8B8);
        end;
      end;

      // detect vertex processing capabilities
      if ((g_D3DCaps.DevCaps and D3DDEVCAPS_HWTRANSFORMANDLIGHT) > 0) and (g_EmuCDPD.DeviceType = D3DDEVTYPE_HAL) then
      begin
        DbgPrintf('EmuD3D8: Using hardware vertex processing');

        g_EmuCDPD.BehaviorFlags := D3DCREATE_HARDWARE_VERTEXPROCESSING;
        g_dwVertexShaderUsage := 0;
      end
      else
      begin
        DbgPrintf('EmuD3D8: Using software vertex processing');

        g_EmuCDPD.BehaviorFlags := D3DCREATE_SOFTWARE_VERTEXPROCESSING;
        g_dwVertexShaderUsage := D3DUSAGE_SOFTWAREPROCESSING;
      end;

      // redirect to windows Direct3D
      g_EmuCDPD.hRet := g_pD3D8.CreateDevice
        (
        g_EmuCDPD.Adapter,
        g_EmuCDPD.DeviceType,
        g_EmuCDPD.hFocusWindow,
        g_EmuCDPD.BehaviorFlags,
        {var}PD3DPRESENT_PARAMETERS(g_EmuCDPD.pPresentationParameters)^, // Dxbx crashes on this argument!
        {out}g_EmuCDPD.ppReturnedDeviceInterface^
        );

      // report error
      if (FAILED(g_EmuCDPD.hRet)) then
      begin
        // Dxbx TODO : Use DXGetErrorDescription(g_EmuCDPD.hRet); (requires another DLL though)
        if (g_EmuCDPD.hRet = D3DERR_INVALIDCALL) then
          CxbxKrnlCleanup('IDirect3D8.CreateDevice failed (Invalid Call)')
        else if (g_EmuCDPD.hRet = D3DERR_NOTAVAILABLE) then
          CxbxKrnlCleanup('IDirect3D8.CreateDevice failed (Not Available)')
        else if (g_EmuCDPD.hRet = D3DERR_OUTOFVIDEOMEMORY) then
          CxbxKrnlCleanup('IDirect3D8.CreateDevice failed (Out of Video Memory)');

        CxbxKrnlCleanup('IDirect3D8.CreateDevice failed (Unknown)');
      end;

      // cache device pointer
      g_pD3DDevice8 := g_EmuCDPD.ppReturnedDeviceInterface^;

      // default NULL guid
      ZeroMemory(@g_ddguid, SizeOf(TGUID));

      // enumerate device guid for this monitor, for directdraw
      hRet := DirectDrawEnumerateExA(@EmuEnumDisplayDevices, nil, DDENUM_ATTACHEDSECONDARYDEVICES);

      // create DirectDraw7
      begin
        if (FAILED(hRet)) then
          hRet := DirectDrawCreateEx(nil, {out} g_pDD7, IID_IDirectDraw7, nil)
        else
          hRet := DirectDrawCreateEx(@g_ddguid, {out} g_pDD7, IID_IDirectDraw7, nil);

        if (FAILED(hRet)) then
          CxbxKrnlCleanup('Could not initialize DirectDraw7');

        hRet := g_pDD7.SetCooperativeLevel(0, DDSCL_NORMAL);
        if (FAILED(hRet)) then
          CxbxKrnlCleanup('Could not set cooperative level');
      end;

      // check for YUY2 overlay support Cxbx TODO: accept other overlay types
      begin
        dwCodes := 0;
        g_pDD7.GetFourCCCodes({var}dwCodes, nil);
        lpCodes := CxbxMalloc(dwCodes * SizeOf(DWORD));
        g_pDD7.GetFourCCCodes({var}dwCodes, lpCodes);

        g_bSupportsYUY2 := False;
        for v := 0 to dwCodes - 1 do
        begin
          if (PArrayOfDWORD(lpCodes)[v] = MAKEFOURCC('Y', 'U', 'Y', '2')) then
          begin
            g_bSupportsYUY2 := True;
            Break;
          end;
        end;

        CxbxFree(lpCodes);

        if (not g_bSupportsYUY2) then
          EmuWarning('YUY2 overlays are not supported in hardware, could be slow!');
      end;

      // initialize primary surface
      if (g_bSupportsYUY2) then
      begin
        ZeroMemory(@ddsd2, SizeOf(ddsd2));
        ddsd2.dwSize := SizeOf(ddsd2);
        ddsd2.dwFlags := DDSD_CAPS;
        ddsd2.ddsCaps.dwCaps := DDSCAPS_PRIMARYSURFACE;
        hRet := g_pDD7.CreateSurface(ddsd2, {out} g_pDDSPrimary, nil);
        if (FAILED(hRet)) then
          CxbxKrnlCleanup('Could not create primary surface (0x%.08X)', [hRet]);
      end;

      // update render target cache
      New({var}g_pCachedRenderTarget);
      g_pCachedRenderTarget.Common := 0;
      g_pCachedRenderTarget.Data := X_D3DRESOURCE_DATA_FLAG_SPECIAL or X_D3DRESOURCE_DATA_FLAG_D3DREND;

      // Dxbx Note : Because g_pCachedRenderTarget.EmuSurface8 must be declared
      // as a property, we can't pass it directly as a var/out parameter.
      // So we use a little work-around here :
      g_pD3DDevice8.GetRenderTarget({out}TmpEmuSurface8);

      g_pCachedRenderTarget.EmuSurface8 := TmpEmuSurface8;
      // Keep this reference around, by fooling the automatic
      // reference-counting Delphi does. (This is necessary
      // because the union-simulation-properties can't do
      // reference-counting either) :
      Pointer(TmpEmuSurface8) := nil;

      // update z-stencil surface cache
      New({var}g_pCachedZStencilSurface);
      g_pCachedZStencilSurface.Common := 0;
      g_pCachedZStencilSurface.Data := X_D3DRESOURCE_DATA_FLAG_SPECIAL or X_D3DRESOURCE_DATA_FLAG_D3DSTEN;

      // Dxbx Note : Because g_pCachedZStencilSurface.EmuSurface8 must be declared
      // as a property, we can't pass it directly as a var/out parameter.
      // So we use a little work-around here :
      g_pD3DDevice8.GetDepthStencilSurface({out}TmpEmuSurface8);
      g_pCachedZStencilSurface.EmuSurface8 := TmpEmuSurface8;
      // Keep this reference around, by fooling the automatic
      // reference-counting Delphi does. (This is necessary
      // because the union-simulation-properties can't do
      // reference-counting either) :
      Pointer(TmpEmuSurface8) := nil;

      g_pD3DDevice8.CreateVertexBuffer(
        {Length=}1,
        {Usage=}0,
        {FVF=}0,
        {Pool=}D3DPOOL_MANAGED,
        {out ppVertexBuffer=}g_pDummyBuffer
        );

      for Streams := 0 to 7 do
      begin
        g_pD3DDevice8.SetStreamSource(Streams, g_pDummyBuffer, 1);
      end;

      // begin scene
      g_pD3DDevice8.BeginScene();

      // initially, show a black screen
      g_pD3DDevice8.Clear(0, nil, D3DCLEAR_TARGET, $FF000000, 0, 0);
      g_pD3DDevice8.Present(nil, nil, 0, nil);

      // signal completion
      g_EmuCDPD.bReady := False;
    end
    else
    begin
      // release direct3d
      if Assigned(g_pD3DDevice8) then
      begin
        DbgPrintf('EmuD3D8: CreateDevice proxy thread releasing old Device.');

        g_pD3DDevice8.EndScene();

        g_EmuCDPD.hRet := g_pD3DDevice8._Release();

        if (g_EmuCDPD.hRet = 0) then
          // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
          Pointer(g_pD3DDevice8) := nil;
      end;

      if (g_bSupportsYUY2) then
      begin
        // cleanup directdraw surface
        if Assigned(g_pDDSPrimary) then
        begin
          g_pDDSPrimary._Release();
          // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
          Pointer(g_pDDSPrimary) := nil;
        end;
      end;

      // cleanup directdraw
      if Assigned(g_pDD7) then
      begin
        g_pDD7._Release();
        // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
        Pointer(g_pDD7) := nil;
      end;

      // signal completion
      g_EmuCDPD.bReady := False;
    end;
  end;

  Result := 0;
end;

// check if a resource has been registered yet (if not, register it)

procedure EmuVerifyResourceIsRegistered(pResource: PX_D3DResource); //inline;
// Branch:martin  Revision:39  Done:60 Translator:Shadow_Tj
var
  v : Integer;
begin
  // 0xEEEEEEEE and 0xFFFFFFFF are somehow set in Halo :(
  if (pResource.Lock <> 0) and (pResource.Lock <> $EEEEEEEE) and (pResource.Lock <> $FFFFFFFF) then
    Exit;

  // Already 'Registered' implicitly
  (*if (( IsSpecialResource(pResource.Data) and ((pResource.Data and X_D3DRESOURCE_DATA_FLAG_D3DREND) or (pResource.Data and X_D3DRESOURCE_DATA_FLAG_D3DSTEN)))
    or (pResource.Data = $B00BBABE)) then
    Exit; *)

  for v := 0 to 15 do begin
    if (pCache[v].Data = pResource.Data) and (pResource.Data <> 0) then
    begin
      pResource.EmuResource8 := pCache[v].EmuResource8;
      Exit;
    end;
  end;

  EmuSwapFS(fsXbox);;
  { TODO: Need to be translated to delphi }
(*  XTL.EmuIDirect3DResource8_Register(pResource, 0 (*(PVOID)pResource.Data*)//);
  EmuSwapFS(fsWindows);

  if (pResource.Lock <> X_D3DRESOURCE_LOCK_FLAG_NOSIZE) then
  begin
    for v := 0 to 15 - 1 do begin
      if (pCache[v].Data = 0) then
      begin
        pCache[v].Data := pResource.Data;
        pCache[v].EmuResource8 := pResource.EmuResource8;
        Break;
      end;

      if (v = 16) then
        CxbxKrnlCleanup('X_D3DResource cache is maxed out!');
    end;
  end;
end;

// ensure a given width/height are powers of 2

procedure EmuAdjustPower2(var dwWidth: UINT; var dwHeight: UINT);
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
var
  NewWidth, NewHeight: uInt;
  v: Integer;
  mask: Integer;
begin
  for v := 0 to 31 do
  begin
    mask := 1 shl v;

    if (dwWidth and mask) > 0 then
      NewWidth := mask;

    if (dwHeight and mask) > 0 then
      NewHeight := mask;
  end;

  if (dwWidth <> NewWidth) then
  begin
    NewWidth := NewWidth shl 1;
    EmuWarning('Needed to resize width (%d.%d)', [dwWidth, NewWidth]);
  end;

  if (dwHeight <> NewHeight) then
  begin
    NewHeight := NewHeight shl 1;
    EmuWarning('Needed to resize height (%d.%d)', [dwHeight, NewHeight]);
  end;

  dwWidth := NewWidth;
  dwHeight := NewHeight;
end;

function XTL_EmuIDirect3D8_CreateDevice(Adapter: UINT; DeviceType: D3DDEVTYPE;
  hFocusWindow: HWND; BehaviorFlags: DWORD;
  pPresentationParameters: PX_D3DPRESENT_PARAMETERS;
  ppReturnedDeviceInterface: PIDirect3DDevice8): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_CreateDevice' +
    #13#10'(' +
    #13#10'   Adapter                  : 0x%.08X' +
    #13#10'   DeviceType               : 0x%.08X' +
    #13#10'   hFocusWindow             : 0x%.08X' +
    #13#10'   BehaviorFlags            : 0x%.08X' +
    #13#10'   pPresentationParameters  : 0x%.08X' +
    #13#10'   ppReturnedDeviceInterface: 0x%.08X' +
    #13#10')', [
    Adapter, Ord(DeviceType), hFocusWindow, BehaviorFlags, pPresentationParameters,
      Pointer(ppReturnedDeviceInterface)
      ]);

  // Cache parameters
  g_EmuCDPD.Adapter := Adapter;
  g_EmuCDPD.DeviceType := DeviceType;
  g_EmuCDPD.hFocusWindow := hFocusWindow;
  g_EmuCDPD.BehaviorFlags := BehaviorFlags;
  g_EmuCDPD.pPresentationParameters := pPresentationParameters;
  g_EmuCDPD.ppReturnedDeviceInterface := ppReturnedDeviceInterface;

  // Wait until proxy is done with an existing call (i highly doubt this situation will come up)
  while (g_EmuCDPD.bReady) do
    Sleep(10); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?

  // Signal proxy thread, and wait for completion
  g_EmuCDPD.bReady := True;
  g_EmuCDPD.bCreate := True;

  // Wait until proxy is completed
  while g_EmuCDPD.bReady do
    Sleep(10); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?

  EmuSwapFS(fsXbox);

  Result := g_EmuCDPD.hRet;
end;

function XTL_EmuIDirect3DDevice8_IsBusy: LONGBOOL; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_IsBusy();');
  EmuWarning('EmuIDirect3DDevice8_IsBusy ignored!');
  EmuSwapFS(fsXbox);
  Result := False;
end;

procedure XTL_EmuIDirect3DDevice8_GetCreationParameters(pParameters: D3DDEVICE_CREATION_PARAMETERS); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetCreationParameters' +
    #13#10'(' +
    #13#10'   pParameters              : 0x%.08X' +
    #13#10');',
    [@pParameters]);

  pParameters.AdapterOrdinal := D3DADAPTER_DEFAULT;
  pParameters.DeviceType := D3DDEVTYPE_HAL;
  pParameters.hFocusWindow := 0;
  pParameters.BehaviorFlags := D3DCREATE_HARDWARE_VERTEXPROCESSING;

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3D8_CheckDeviceFormat(Adapter: UINT; DeviceType: D3DDEVTYPE;
  AdapterFormat: X_D3DFORMAT; Usage: DWORD; RType: _D3DRESOURCETYPE; CheckFormat: X_D3DFORMAT): HRESULT; stdcall;
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  hRet := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_CheckDeviceFormat' +
    #13#10'(' +
    #13#10'   Adapter                  : 0x%.08X' +
    #13#10'   DeviceType               : 0x%.08X' +
    #13#10'   AdapterFormat            : 0x%.08X' +
    #13#10'   Usage                    : 0x%.08X' +
    #13#10'   RType                    : 0x%.08X' +
    #13#10'   CheckFormat              : 0x%.08X' +
    #13#10');',
    [Adapter, @DeviceType, @AdapterFormat,
    Usage, @RType, CheckFormat]);

  if (Ord(RType) > 7) then
    CxbxKrnlCleanup('RType > 7');


  hRet := g_pD3D8.CheckDeviceFormat
    (
    g_XBVideo.GetDisplayAdapter(),
    iif(g_XBVideo.GetDirect3DDevice() = 0, D3DDEVTYPE_HAL, D3DDEVTYPE_REF),
    EmuXB2PC_D3DFormat(AdapterFormat),
    Usage, RType, EmuXB2PC_D3DFormat(CheckFormat)
    );

  EmuSwapFS(fsXbox);
  Result := hRet;
end;

procedure XTL_EmuIDirect3DDevice8_GetDisplayFieldStatus(pFieldStatus: X_D3DFIELD_STATUS); stdcall;
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetDisplayFieldStatus' +
    #13#10'(' +
    #13#10'   pFieldStatus             : 0x%.08X' +
    #13#10');',
    [@pFieldStatus]);

  pFieldStatus.Field := X_D3DFIELDTYPE(iif(g_VBData.VBlank and 1 = 0, Ord(X_D3DFIELD_ODD), Ord(X_D3DFIELD_EVEN)));
  pFieldStatus.VBlankCount := g_VBData.VBlank;

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_BeginPush(Count: DWORD): DWORD; stdcall;
// Branch:martin  Revision:39  Done:100 Translator:Shadow_Tj
var
  pRet: DWORD;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BeginPush(%d);', [Count]);

  pRet := Count;
  g_dwPrimaryPBCount := Count;
  g_pPrimaryPB := pRet;

  EmuSwapFS(fsXbox);

  Result := pRet;
end;

procedure XTL_EmuIDirect3DDevice8_EndPush(pPush: DWord); stdcall;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_EndPush(0x%.08X);', [pPush]);

  XTL_EmuExecutePushBufferRaw(g_pPrimaryPB);

    { TODO: Need to be translated to delphi }
    (*
    delete[] g_pPrimaryPB; *)

  g_pPrimaryPB := 0;


  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_BeginVisibilityTest: HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BeginVisibilityTest();');
  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_EndVisibilityTest(Index: DWord): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_EndVisibilityTest' +
    #13#10'(' +
    #13#10'   Index                    : 0x%.08X' +
    #13#10');)',
    [Index]);
  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

procedure XTL_EmuIDirect3DDevice8_SetBackBufferScale(x, y: Single);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetBackBufferScale' +
    #13#10'(' +
    #13#10'   x                        :  0x%f' +
    #13#10'   y                        :  0x%f' +
    #13#10');',
    [x, y]);
  EmuWarning('SetBackBufferScale ignored');
  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_GetVisibilityTestResult(Index: DWORD;
  var pResult: UINT; var pTimeStamp: ULONGLONG): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVisibilityTestResult' +
    #13#10'(' +
    #13#10'   Index                    : 0x%.08X' +
    #13#10'   pResult                  : 0x%.08X' +
    #13#10'   pTimeStamp               : 0x%.08X' +
    #13#10');',
    [Index, pResult, pTimeStamp]);

    // Cxbx TODO : actually emulate this!?

  if pResult <> 0 then
    {var}pResult := 640 * 480;

  if pTimeStamp <> 0 then
    {var}pTimeStamp := 0;

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

procedure XTL_EmuIDirect3DDevice8_GetDeviceCaps(pCaps: D3DCAPS8);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetDeviceCaps' +
    #13#10'(' +
    #13#10'   pCaps                    : 0x%.08X' +
    #13#10');',
    [@pCaps]);

  g_pD3D8.GetDeviceCaps(g_XBVideo.GetDisplayAdapter(), iif(g_XBVideo.GetDirect3DDevice = 0, D3DDEVTYPE_HAL, D3DDEVTYPE_REF), pCaps);

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_LoadVertexShader(Handle: DWord; Address: DWord): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pVertexShader: PVERTEX_SHADER;
  i: Integer;
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_LoadVertexShader' +
    #13#10'(' +
    #13#10'   Handle             : 0x%.08X' +
    #13#10'   Address            : 0x%.08X' +
    #13#10');',
    [Handle, Address]);

  if (Address < 136) and VshHandleIsVertexShader(Handle) then
  begin
    pVertexShader := PVERTEX_SHADER(VshHandleGetVertexShader(Handle).Handle);
    for i := Address to pVertexShader.Size - 1 do
    begin
      // Cxbx TODO: This seems very fishy
      g_VertexShaderSlots[i] := Handle;
    end;
  end;

  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_SelectVertexShader(Handle: DWord; Address: DWord): HRESULT;
// Branch:martin  Revision:39 Done:20 Translator:Shadow_Tj
var
  pVertexShader: VERTEX_SHADER;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SelectVertexShader' +
    #13#10'(' +
    #13#10'   Handle             : 0x%.08X' +
    #13#10'   Address            : 0x%.08X' +
    #13#10');',
    [Handle, Address]);

  if (VshHandleIsVertexShader(Handle)) then
  begin
    (*
    pVertexShader := (VERTEX_SHADER )(((X_D3DVertexShader )(Handle and $7FFFFFFF)).Handle);
    g_pD3DDevice8.SetVertexShader(pVertexShader.aHandle);
    *)
  end
  else if (Handle = 0) then
  begin
    g_pD3DDevice8.SetVertexShader(D3DFVF_XYZ or D3DFVF_TEX0);
  end
  else if (Address < 136) then
  begin
    (*
    pVertexShader := g_VertexShaderSlots[Address];

    if(pVertexShader <> 0) then
    begin
        g_pD3DDevice8.SetVertexShader(((VERTEX_SHADER )((X_D3DVertexShader )g_VertexShaderSlots[Address]).Handle).Handle);
    end
    else
    begin
        EmuWarning('g_VertexShaderSlots[%d] := 0', Address);
    end;
    *)
  end;

  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

function XTL_EmuIDirect3D8_GetAdapterModeCount(Adapter: DWord): DWord;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: UINT;
  Mode: D3DDISPLAYMODE;
  v: uInt32;
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_GetAdapterModeCount' +
    #13#10'(' +
    #13#10'   Adapter                  : 0x%.08X' +
    #13#10');',
    [Adapter]);

  ret := g_pD3D8.GetAdapterModeCount(g_XBVideo.GetDisplayAdapter);

  for v := 0 to ret - 1 do
  begin
    hRet := g_pD3D8.EnumAdapterModes(g_XBVideo.GetDisplayAdapter, v, Mode);

    if (hRet <> D3D_OK) then
      Break;

    if (Mode.Width <> 640) or (Mode.Height <> 480) then
      ret := ret - 1;
  end;

  EmuSwapFS(fsXbox);
  Result := ret;
end;

function XTL_EmuIDirect3D8_GetAdapterDisplayMode(Adapter: UINT; pMode: X_D3DDISPLAYMODE): HRESULT;
// Branch:martin  Revision:39 Done:20 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pPCMode: D3DDISPLAYMODE;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_GetAdapterDisplayMode' +
    #13#10'(' +
    #13#10'   Adapter                  : 0x%.08X' +
    #13#10'   pMode                    : 0x%.08X' +
    #13#10');',
    [@Adapter, @pMode]);

  // NOTE: WARNING: We should cache the 'Emulated' display mode and return
  // This value. We can initialize the cache with the default Xbox mode data.
  (*hRet := g_pD3D8.GetAdapterDisplayMode( g_XBVideo.GetDisplayAdapter(), pMode);

  // make adjustments to the parameters to make sense with windows direct3d
  pPCMode := pMode;

  // Convert Format (PC->Xbox)
  pMode.Format := EmuPC2XB_D3DFormat(pPCMode.Format); *)

  // Cxbx TODO: Make this configurable in the future?
  // D3DPRESENTFLAG_FIELD | D3DPRESENTFLAG_INTERLACED | D3DPRESENTFLAG_LOCKABLE_BACKBUFFER
  pMode.Flags := $000000A1;

  // Cxbx TODO: Retrieve from current CreateDevice settings?
  pMode.Width := 640;
  pMode.Height := 480;
  EmuSwapFS(fsXbox);
  Result := hRet;
end;

function XTL_EmuIDirect3D8_EnumAdapterModes(Adapter: UINT; Mode: UINT; pMode: X_D3DDISPLAYMODE): HRESULT;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  ModeAdder: Integer;
  PCMode: D3DDISPLAYMODE;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_EnumAdapterModes' +
    #13#10'(' +
    #13#10'   Adapter                  : 0x%.08X' +
    #13#10'   Mode                     : 0x%.08X' +
    #13#10'   pMode                    : 0x%.08X' +
    #13#10');',
    [@Adapter, @Mode, @pMode]);


  ModeAdder := 0;

  if (Mode = 0) then
    ModeAdder := 0;

    { TODO: need to be translated to delphi }
    (*


    while True do
    begin
        hRet := g_pD3D8.EnumAdapterModes(g_XBVideo.GetDisplayAdapter(), Mode+ModeAdder, (D3DDISPLAYMODE)@PCMode);

        if(hRet <> D3D_OK or (PCMode.Width = 640 and PCMode.Height = 480)) then
            Break;

        ModeAdder:= ModeAdder + 1;
    end;
    *)

    // make adjustments to parameters to make sense with windows direct3d
  if (hRet = D3D_OK) then
  begin
        //
        // NOTE: WARNING: PC D3DDISPLAYMODE is different than Xbox D3DDISPLAYMODE!
        //

        // Convert Format (PC->Xbox)
    pMode.Width := PCMode.Width;
    pMode.Height := PCMode.Height;
    pMode.RefreshRate := PCMode.RefreshRate;

        // Cxbx TODO: Make this configurable in the future?
        // D3DPRESENTFLAG_FIELD | D3DPRESENTFLAG_INTERLACED | D3DPRESENTFLAG_LOCKABLE_BACKBUFFER
    pMode.Flags := $000000A1;

    { TODO -oDxbx: Need to be translated to delphi }
    (*
    pMode.Format := XTL_EmuPC2XB_D3DFormat(PCMode.Format)
    *)
  end
  else
  begin
    hRet := D3DERR_INVALIDCALL;
  end;

  EmuSwapFS(fsXbox);
  Result := hRet;
end;

procedure XTL_EmuIDirect3D8_KickOffAndWaitForIdle;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3D8_KickOffAndWaitForIdle();');
  // Cxbx TODO: Actually do something here?
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3D8_KickOffAndWaitForIdle2(dwDummy1, dwDummy2: DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3D8_KickOffAndWaitForIdle' +
    #13#10'(' +
    #13#10'   dwDummy1           : 0x%.08X' +
    #13#10'   dwDummy2           : 0x%.08X' +
    #13#10');',
    [dwDummy1, dwDummy2]);
    // Cxbx TODO: Actually do something here?
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetGammaRamp(dwFlags: DWORD; pRamp: X_D3DGAMMARAMP);
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetGammaRamp' +
    #13#10'(' +
    #13#10'   dwFlags            : 0x%.08X' +
    #13#10'   pRamp              : 0x%.08X' +
    #13#10');',
    [dwFlags, @pRamp]);

{ TODO: Need to be translated to delphi }
    // remove D3DSGR_IMMEDIATE
(*    DWORD dwPCFlags := dwFlags and (~$00000002);
    D3DGAMMARAMP PCRamp;

    for(Integer v:=0;v<255;v++)
    begin
        PCRamp.red[v]   := pRamp.red[v];
        PCRamp.green[v] := pRamp.green[v];
        PCRamp.blue[v]  := pRamp.blue[v];
     end;

    g_pD3DDevice8.SetGammaRamp(dwPCFlags, @PCRamp);
*)
  EmuSwapFS(fsXbox);

end;

function XTL_EmuIDirect3DDevice8_AddRef(): ULONG; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: ULONG;
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_AddRef()');
  ret := g_pD3DDevice8._AddRef();
  EmuSwapFS(fsXbox);
  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_BeginStateBlock: HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: ULONG;
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BeginStateBlock();');

  ret := g_pD3DDevice8.BeginStateBlock();
  EmuSwapFS(fsXbox);
  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_BeginStateBig: HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: ULONG;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BeginStateBig();');
  ret := g_pD3DDevice8.BeginStateBlock();

  CxbxKrnlCleanup('BeginStateBig is not implemented');
  EmuSwapFS(fsXbox);
  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_CaptureStateBlock(Token: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: ULONG;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CaptureStateBlock' +
    #13#10'(' +
    #13#10'   Token              : 0x%.08X' +
    #13#10');',
    [Token]);

  ret := g_pD3DDevice8.CaptureStateBlock(Token);
  EmuSwapFS(fsXbox);
  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_ApplyStateBlock(Token: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: ULONG;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_ApplyStateBlock' +
    #13#10'(' +
    #13#10'   Token              : 0x%.08X' +
    #13#10');',
    [Token]);

  ret := g_pD3DDevice8.ApplyStateBlock(Token);

  EmuSwapFS(fsXbox);

  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_EndStateBlock(pToken: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ret: LONG;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_EndStateBlock' +
    #13#10'(' +
    #13#10'   pToken             : 0x%.08X' +
    #13#10');',
    [pToken]);

  ret := g_pD3DDevice8.EndStateBlock(pToken);

  EmuSwapFS(fsXbox);

  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_CopyRects(pSourceSurface: PX_D3DSurface;
  pSourceRectsArray: PRECT;
  cRects: UINT;
  pDestinationSurface: PX_D3DSurface;
  pDestPointsArray: PPoint): HRESULT;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
var
  hRet: HRESULT;
  kthx: Integer;
  FileName: array[0..255 - 1] of Char;
  ahRet: HRESULT;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CopyRects' +
    #13#10'(' +
    #13#10'   pSourceSurface     : 0x%.08X' +
    #13#10'   pSourceRectsArray  : 0x%.08X' +
    #13#10'   cRects             : 0x%.08X' +
    #13#10'   pDestinationSurface: 0x%.08X' +
    #13#10'   pDestPointsArray   : 0x%.08X' +
    #13#10');',
    [pSourceSurface, pSourceRectsArray, cRects,
    pDestinationSurface, pDestPointsArray]);

  pSourceSurface.EmuSurface8.UnlockRect();


  kthx := 0;
    (*StrFmt(FileName, 'C:\Aaron\Textures\SourceSurface-%d.bmp', kthx++); *)

  D3DXSaveSurfaceToFile(FileName, D3DXIFF_BMP, pSourceSurface.EmuSurface8, nil, nil);

  ahRet := g_pD3DDevice8.CopyRects
    (
    pSourceSurface.EmuSurface8,
    pSourceRectsArray,
    cRects,
    pDestinationSurface.EmuSurface8,
    pDestPointsArray
    );

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_CreateImageSurface(
  Width: UINT; Height: UINT; aFormat: X_D3DFORMAT; ppBackBuffer: PPX_D3DSurface): HRESULT;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  PCFormat: D3DFORMAT;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateImageSurface' +
    #13#10'(' +
    #13#10'   Width              : 0x%.08X' +
    #13#10'   Height             : 0x%.08X' +
    #13#10'   Format             : 0x%.08X' +
    #13#10'   ppBackBuffer       : 0x%.08X' +
    #13#10');',
    [Width, Height, aFormat, ppBackBuffer]);

    (*pBackBuffer := X_D3DSurface;

  PCFormat := XTL_EmuXB2PC_D3DFormat(aFormat);
    hRet := g_pD3DDevice8.CreateImageSurface(Width, Height, PCFormat, ppBackBuffer.EmuSurface8);
      *)
  EmuSwapFS(fsXbox);
  Result := hRet;
end;

procedure XTL_EmuIDirect3DDevice8_GetGammaRamp(pRamp: X_D3DGAMMARAMP);
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetGammaRamp' +
    #13#10'(' +
    #13#10'   pRamp              : 0x%.08X' +
    #13#10');',
    [@pRamp]);

    { TODO: Need to be translated to delphi }
    (*D3DGAMMARAMP *pGammaRamp := (D3DGAMMARAMP )malloc(SizeOf(D3DGAMMARAMP));

    g_pD3DDevice8.GetGammaRamp(pGammaRamp);

    for(Integer v:=0;v<256;v++)
    begin
        pRamp.red[v] := (BYTE)pGammaRamp.red[v];
        pRamp.green[v] := (BYTE)pGammaRamp.green[v];
        pRamp.blue[v] := (BYTE)pGammaRamp.blue[v];
     end;

    free(pGammaRamp); *)

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_GetBackBuffer2(BackBuffer: Integer): PX_D3DSurface; stdcall;
// Branch:martin  Revision:39 Done:5 Translator:Shadow_Tj
begin
  Result := nil;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetBackBuffer2' +
    #13#10'(' +
    #13#10'   BackBuffer         : 0x%.08X' +
    #13#10');',
    [BackBuffer]);

    { unsafe, somehow
    HRESULT hRet := S_OK;

    X_D3DSurface *pBackBuffer := new X_D3DSurface();

    if(BackBuffer = -1) then
    begin
         IDirect3DSurface8 *pCachedPrimarySurface := 0;

        if(pCachedPrimarySurface = 0) then
        begin
            // create a buffer to return
            // Cxbx TODO: Verify the surface is always 640x480
            g_pD3DDevice8.CreateImageSurface(640, 480, D3DFMT_A8R8G8B8, @pCachedPrimarySurface);
         end;

        pBackBuffer.EmuSurface8 := pCachedPrimarySurface;

        hRet := g_pD3DDevice8.GetFrontBuffer(pBackBuffer.EmuSurface8);

        if(FAILED(hRet)) then
        begin
            EmuWarning('Could not retrieve primary surface, using backbuffer');
            pCachedPrimarySurface := 0;
            pBackBuffer.EmuSurface8.Release();
            pBackBuffer.EmuSurface8 := nil;
            BackBuffer := 0;
         end;

        // Debug: Save this image temporarily
        //D3DXSaveSurfaceToFile('C:\\Aaron\\Textures\\FrontBuffer.bmp', D3DXIFF_BMP, pBackBuffer.EmuSurface8, NULL, NULL);
     end;

    if(BackBuffer <> -1) then
        hRet := g_pD3DDevice8.GetBackBuffer(BackBuffer, D3DBACKBUFFER_TYPE_MONO,  and (pBackBuffer.EmuSurface8));
    }

   { TODO: need to be translated to delphi }
(*     X_D3DSurface *pBackBuffer := new X_D3DSurface();

    if(BackBuffer = -1) then
        BackBuffer := 0;

    HRESULT hRet := g_pD3DDevice8.GetBackBuffer(BackBuffer, D3DBACKBUFFER_TYPE_MONO,  and (pBackBuffer.EmuSurface8));

    if(FAILED(hRet)) then
        CxbxKrnlCleanup('Unable to retrieve back buffer');

    // update data pointer
    pBackBuffer.Data := X_D3DRESOURCE_DATA_FLAG_SPECIAL or X_D3DRESOURCE_DATA_FLAG_SURFACE;

    EmuSwapFS(fsXbox);

    Result := pBackBuffer;          *)
end;

procedure XTL_EmuIDirect3DDevice8_GetBackBuffer(
  BackBuffer: INT;
  cType: D3DBACKBUFFER_TYPE;
  ppBackBuffer: PPX_D3DSurface);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
    // debug trace
{$IFDEF _DEBUG_TRACE}
  begin
    EmuSwapFS(fsWindows);
    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetBackBuffer' +
      #13#10'(' +
      #13#10'   BackBuffer         : 0x%.08X' +
      #13#10'   cType               : 0x%.08X' +
      #13#10'   ppBackBuffer       : 0x%.08X' +
      #13#10');',
      [BackBuffer, Ord(cType), ppBackBuffer]);
    EmuSwapFS(fsXbox);
  end;
{$ENDIF}

  ppBackBuffer^ := XTL_EmuIDirect3DDevice8_GetBackBuffer2(BackBuffer);
end;

function XTL_EmuIDirect3DDevice8_SetViewport(pViewport: D3DVIEWPORT8): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
  dwWidth: DWORD;
  dwHeight: DWORD;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetViewport' +
    #13#10'(' +
    #13#10'   pViewport          : 0x%.08X (%d, %d, %d, %d, %f, %f)' +
    #13#10');',
    [@pViewport, pViewport.X, pViewport.Y, pViewport.Width,
    pViewport.Height, pViewport.MinZ, pViewport.MaxZ]);

  dwWidth := pViewport.Width;
  dwHeight := pViewport.Height;

  // resize to fit screen (otherwise crashes occur)
  begin
    if (dwWidth <> 640) then
    begin
      EmuWarning('Resizing Viewport.Width to 640');
      pViewport.Width := 640;
    end;

    if (dwHeight <> 480) then
    begin
      EmuWarning('Resizing Viewport.Height to 480');
      pViewport.Height := 480;
    end;
  end;

  hRet := g_pD3DDevice8.SetViewport(pViewport);

  // restore originals
  begin
    if (dwWidth > 640) then
      pViewport.Width := dwWidth;

    if (dwHeight > 480) then
      pViewport.Height := dwHeight;
  end;

  if (FAILED(hRet)) then
  begin
    EmuWarning('Unable to set viewport!');
    hRet := D3D_OK;
  end;

  EmuSwapFS(fsXbox);
  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_GetViewport(pViewport: D3DVIEWPORT8): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetViewport' +
    #13#10'(' +
    #13#10'   pViewport          : 0x%.08X' +
    #13#10');',
    [@pViewport]);

  hRet := g_pD3DDevice8.GetViewport(pViewport);

  if (FAILED(hRet)) then
  begin
    EmuWarning('Unable to get viewport!');
    hRet := D3D_OK;
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

procedure XTL_EmuIDirect3DDevice8_GetViewportOffsetAndScale(pOffset: TD3DXVECTOR4; pScale: TD3DXVECTOR4); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  fScaleX: Single;
  fScaleY: Single;
  fScaleZ: Single;
  fOffsetX: Single;
  fOffsetY: Single;
  Viewport: D3DVIEWPORT8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetViewportOffsetAndScale' +
    #13#10'(' +
    #13#10'   pOffset            : 0x%.08X' +
    #13#10'   pScale             : 0x%.08X' +
    #13#10');',
    [@pOffset, @pScale]);

  fScaleX := 1.0;
  fScaleY := 1.0;
  fScaleZ := 1.0;
  fOffsetX := 0.5 + 1.0 / 32;
  fOffsetY := 0.5 + 1.0 / 32;

  EmuSwapFS(fsXbox);
  XTL_EmuIDirect3DDevice8_GetViewport(Viewport);
  EmuSwapFS(fsWindows);

  pScale.x := 1.0;
  pScale.y := 1.0;
  pScale.z := 1.0;
  pScale.w := 1.0;

  pOffset.x := 0.0;
  pOffset.y := 0.0;
  pOffset.z := 0.0;
  pOffset.w := 0.0;

  pScale.x := Viewport.Width * 0.5 * fScaleX;
  pScale.y := Viewport.Height * -0.5 * fScaleY;
  pScale.z := (Viewport.MaxZ - Viewport.MinZ) * fScaleZ;
  pScale.w := 0;

  pOffset.x := Viewport.Width * fScaleX * 0.5 + Viewport.X * fScaleX + fOffsetX;
  pOffset.y := Viewport.Height * fScaleY * 0.5 + Viewport.Y * fScaleY + fOffsetY;
  pOffset.z := Viewport.MinZ * fScaleZ;
  pOffset.w := 0;

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetShaderConstantMode(Mode: X_VERTEXSHADERCONSTANTMODE): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetShaderConstantMode' +
    #13#10'(' +
    #13#10'   Mode               : 0x%.08X' +
    #13#10');',
    [Mode]);

  g_VertexShaderConstantMode := Mode;
  EmuSwapFS(fsXbox);

  Result := S_OK;
end;


function XTL_EmuIDirect3DDevice8_Reset(pPresentationParameters: PX_D3DPRESENT_PARAMETERS): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_Reset' +
    #13#10'(' +
    #13#10'   pPresentationParameters : 0x%.08X' +
    #13#10');',
    [pPresentationParameters]);
  EmuWarning('Device Reset is being utterly ignored');
  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_GetRenderTarget(ppRenderTarget: PPX_D3DSurface): HRESULT;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
var
  pSurface8: IDirect3DSurface8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetRenderTarget' +
    #13#10'(' +
    #13#10'   ppRenderTarget     : 0x%.08X' +
    #13#10');',
    [ppRenderTarget]);

  pSurface8 := g_pCachedRenderTarget.EmuSurface8;

    (*pSurface8.AddRef(); *)

  ppRenderTarget^ := g_pCachedRenderTarget;

  DbgPrintf('EmuD3D8: RenderTarget := 0x%.08X', pSurface8);

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_GetRenderTarget2(): PX_D3DSurface;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pSurface8: IDirect3DSurface8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetRenderTarget2()');

  pSurface8 := g_pCachedRenderTarget.EmuSurface8;

  pSurface8._AddRef();

  DbgPrintf('EmuD3D8: RenderTarget := 0x%.08X', pSurface8);

  EmuSwapFS(fsXbox);

  Result := g_pCachedRenderTarget;
end;

function XTL_EmuIDirect3DDevice8_GetDepthStencilSurface(ppZStencilSurface: PPX_D3DSurface): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pSurface8: IDirect3DSurface8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetDepthStencilSurface' +
    #13#10'(' +
    #13#10'   ppZStencilSurface  : 0x%.08X' +
    #13#10');',
    [ppZStencilSurface]);

  pSurface8 := g_pCachedZStencilSurface.EmuSurface8;

  if Assigned(pSurface8) then
    pSurface8._AddRef();

  ppZStencilSurface^ := g_pCachedZStencilSurface;

  DbgPrintf('EmuD3D8: DepthStencilSurface := 0x%.08X', pSurface8);
  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_GetDepthStencilSurface2(): PX_D3DSurface;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pSurface8: IDirect3DSurface8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetDepthStencilSurface2()');

  pSurface8 := g_pCachedZStencilSurface.EmuSurface8;

  if Assigned(pSurface8) then
    pSurface8._AddRef();

  DbgPrintf('EmuD3D8: DepthStencilSurface := 0x%.08X', pSurface8);

  EmuSwapFS(fsXbox);

  Result := g_pCachedZStencilSurface;
end;

function XTL_EmuIDirect3DDevice8_GetTile(Index: DWORD; pTile: PX_D3DTILE): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetTile' +
    #13#10'(' +
    #13#10'   Index              : 0x%.08X' +
    #13#10'   pTile              : 0x%.08X' +
    #13#10');',
    [Index, @pTile]);

  if Assigned(pTile) then
    memcpy(pTile, @(EmuD3DTileCache[Index]), SizeOf(X_D3DTILE));

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_SetTileNoWait(Index: DWORD; pTile: PX_D3DTILE): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTileNoWait' +
    #13#10'(' +
    #13#10'   Index              : 0x%.08X' +
    #13#10'   pTile              : 0x%.08X' +
    #13#10');',
    [Index, @pTile]);

    (*if(pTile <> 0) then
       move ( pTile, @EmuD3DTileCache[Index], SizeOf(X_D3DTILE) ); *)

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_CreateVertexShader(pDeclaration: DWORD;
  pFunction: DWORD;
  pHandle: DWORD;
  Usage: DWORD): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateVertexShader' +
    #13#10'(' +
    #13#10'   pDeclaration       : 0x%.08X' +
    #13#10'   pFunction          : 0x%.08X' +
    #13#10'   pHandle            : 0x%.08X' +
    #13#10'   Usage              : 0x%.08X' +
    #13#10');',
    [pDeclaration, pFunction, pHandle, Usage]);

    // create emulated shader struct
    (*X_D3DVertexShader *pD3DVertexShader := (X_D3DVertexShader)CxbxMalloc(SizeOf(X_D3DVertexShader));
    VERTEX_SHADER     *pVertexShader := (VERTEX_SHADER)CxbxMalloc(SizeOf(VERTEX_SHADER));

    // Cxbx TODO: Intelligently fill out these fields as necessary
    ZeroMemory(pD3DVertexShader, SizeOf(X_D3DVertexShader));
    ZeroMemory(pVertexShader, SizeOf(VERTEX_SHADER));

    // HACK: Cxbx TODO: support this situation
    if(pDeclaration = 0) then
    begin
        *pHandle := 0;

        EmuSwapFS(fsWindows);

        Result := S_OK;
     end;

    LPD3DXBUFFER pRecompiledBuffer := 0;
    DWORD        *pRecompiledDeclaration;
    DWORD        *pRecompiledFunction := 0;
    DWORD        VertexShaderSize;
    DWORD        DeclarationSize;
    DWORD        Handle := 0;

    HRESULT hRet = XTL.EmuRecompileVshDeclaration((DWORD)pDeclaration,
                                                   @pRecompiledDeclaration,
                                                   @DeclarationSize,
                                                   pFunction = 0,
                                                   @pVertexShader.VertexDynamicPatch);

    if(SUCCEEDED(hRet) and pFunction) then
    begin
        hRet = XTL.EmuRecompileVshFunction((DWORD)pFunction,
                                            @pRecompiledBuffer,
                                            @VertexShaderSize,
                                            g_VertexShaderConstantMode := X_VSCM_NONERESERVED);
        if(SUCCEEDED(hRet)) then
        begin
            pRecompiledFunction := (DWORD)pRecompiledBuffer.GetBufferPointer();
         end;
        else
        begin
            pRecompiledFunction := 0;
            EmuWarning('Couldn't recompile vertex shader function.': );
            hRet := D3D_OK; // Try using a fixed function vertex shader instead
         end;
     end;

    //DbgPrintf('MaxVertexShaderConst = %d', [g_D3DCaps.MaxVertexShaderConst]);

    if(SUCCEEDED(hRet)) then
    begin
        hRet = g_pD3DDevice8.CreateVertexShader
        (
            pRecompiledDeclaration,
            pRecompiledFunction,
            @Handle,
            g_dwVertexShaderUsage   // Cxbx TODO: HACK: Xbox has extensions!
        );
        if(pRecompiledBuffer) then
        begin
            pRecompiledBuffer.Release();
            pRecompiledBuffer := 0;
         end;
     end;
    // Save the status, to remove things later
    pVertexShader.Status := hRet;

    CxbxFree(pRecompiledDeclaration);

    pVertexShader.pDeclaration := (DWORD)CxbxMalloc(DeclarationSize);
    move( pDeclaration, pVertexShader.pDeclaration, DeclarationSize );

    pVertexShader.FunctionSize := 0;
    pVertexShader.pFunction := 0;
    pVertexShader.cType := X_VST_NORMAL;
    pVertexShader.Size := (VertexShaderSize - SizeOf(VSH_SHADER_HEADER)) / VSH_INSTRUCTION_SIZE_BYTES;
    pVertexShader.DeclarationSize := DeclarationSize;

    if(SUCCEEDED(hRet)) then
    begin
        if(pFunction <> 0) then
        begin
            pVertexShader.pFunction := (DWORD)CxbxMalloc(VertexShaderSize);
            move ( pFunction, pVertexShader.pFunction, VertexShaderSize );
            pVertexShader.FunctionSize := VertexShaderSize;
         end;
        else
        begin
            pVertexShader.pFunction := 0;
            pVertexShader.FunctionSize := 0;
         end;
        pVertexShader.Handle := Handle;
     end;
    else
    begin
        pVertexShader.Handle := D3DFVF_XYZ or D3DFVF_TEX0;
     end;

    pD3DVertexShader.Handle := (DWORD)pVertexShader;

    *pHandle := ((DWORD)pD3DVertexShader) or $80000000;

    if(FAILED(hRet)) then
    begin
#ifdef _DEBUG_TRACK_VS
        if (pFunction) then
        begin
             pFileName: array [0..30-1] of Char;
             Integer FailedShaderCount := 0;
            VSH_SHADER_HEADER *pHeader := (VSH_SHADER_HEADER)pFunction;
            EmuWarning('Couldn't create vertex shader!');
            StrFmt(pFileName, 'failed%05d.xvu', FailedShaderCount);
            FILE *f := FileOpen(pFileName, 'wb');
            if(f) then
            begin
                FileWrite(pFunction, SizeOf(VSH_SHADER_HEADER) + pHeader.NumInst * 16, 1, f);
                FileClose(f);
             end;
            FailedShaderCount:= FailedShaderCount + 1;
         end;
//endif // _DEBUG_TRACK_VS
        //hRet = D3D_OK;
     end;
     *)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

procedure XTL_EmuIDirect3DDevice8_SetPixelShaderConstant(aRegister: DWORD;
  pConstantData: PVOID;
  ConstantCount: DWORD); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetPixelShaderConstant' +
    #13#10'(' +
    #13#10'   Register           : 0x%.08X' +
    #13#10'   pConstantData      : 0x%.08X' +
    #13#10'   ConstantCount      : 0x%.08X' +
    #13#10');',
    [aRegister, pConstantData, ConstantCount]);

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetVertexShaderConstant(
  aRegister: INT;
  const pConstantData: PVOID;
  ConstantCount: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
var
  hRet: HRESULT;
  {$IFDEF _DEBUG_TRACK_VS_CONST}
  i: integer;
  {$ENDIF}
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexShaderConstant' +
    #13#10'(' +
    #13#10'   Register           : 0x%.08X' +
    #13#10'   pConstantData      : 0x%.08X' +
    #13#10'   ConstantCount      : 0x%.08X' +
    #13#10');',
    [aRegister, pConstantData, ConstantCount]);

{$IFDEF _DEBUG_TRACK_VS_CONST}
  for (i := 0 to ConstantCount - 1) do
  begin
        (*printf('SetVertexShaderConstant, c%d (c%d) := ( %f, %f, %f, %f  end;',
               aRegister - 96 + i, aRegister + i,
               *((Single)pConstantData + 4 * i),
               *((Single)pConstantData + 4 * i + 1),
               *((Single)pConstantData + 4 * i + 2),
               *((Single)pConstantData + 4 * i + 3)); *)
  end;
{$ENDIF}

  hRet := g_pD3DDevice8.SetVertexShaderConstant
    (
    aRegister,
    pConstantData,
    ConstantCount
    );

  if (FAILED(hRet)) then
  begin
    EmuWarning('We''re lying about setting a vertex shader constant!');

    hRet := D3D_OK;
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

procedure XTL_EmuIDirect3DDevice8_SetVertexShaderConstant1(
  aRegister: INT;
  const pConstantData: PVOID); register;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
    // debug trace
{$IFDEF _DEBUG_TRACE}
  begin
    EmuSwapFS(fsWindows);
    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexShaderConstant1' +
      #13#10'(' +
      #13#10'   Register           : 0x%.08X' +
      #13#10'   pConstantData      : 0x%.08X' +
      #13#10');',
      [aRegister, pConstantData]);
    EmuSwapFS(fsXbox);
  end;
{$ENDIF}

  XTL_EmuIDirect3DDevice8_SetVertexShaderConstant(aRegister, pConstantData, 1);
end;

procedure XTL_EmuIDirect3DDevice8_SetVertexShaderConstant4(
  aRegister: INT;
  const pConstantData: PVOID); register;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
    // debug trace
{$IFDEF _DEBUG_TRACE}
  begin
    EmuSwapFS(fsWindows);
    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexShaderConstant4' +
      #13#10'(' +
      #13#10'   Register           : 0x%.08X' +
      #13#10'   pConstantData      : 0x%.08X' +
      #13#10');',
      [aRegister, pConstantData]);
    EmuSwapFS(fsXbox);
  end;
{$ENDIF}

  XTL_EmuIDirect3DDevice8_SetVertexShaderConstant(aRegister, pConstantData, 4);
end;

{ TODO: Need to be translated to delphi }

procedure XTL_EmuIDirect3DDevice8_SetVertexShaderConstantNotInline(
  aRegister: INT;
  const pConstantData: PVOID;
  ConstantCount: DWORD); register;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
begin
    // debug trace
{$IFDEF _DEBUG_TRACE}
  begin
    EmuSwapFS(fsWindows);
    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexShaderConstantNotInline' +
      #13#10'(' +
      #13#10'   Register           : 0x%.08X' +
      #13#10'   pConstantData      : 0x%.08X' +
      #13#10'   ConstantCount      : 0x%.08X' +
      #13#10');',
      [aRegister, pConstantData, ConstantCount]);
    EmuSwapFS(fsXbox);
  end;
{$ENDIF}

    (*XTL_EmuIDirect3DDevice8_SetVertexShaderConstant(aRegister, pConstantData, ConstantCount / 4); *)
end;

procedure XTL_EmuIDirect3DDevice8_DeletePixelShader(Handle: DWORD); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_DeletePixelShader' +
    #13#10'(' +
    #13#10'   Handle             : 0x%.08X' +
    #13#10');',
    Handle);

  if (Handle = X_PIXELSHADER_FAKE_HANDLE) then
  begin
        // Do Nothing!
  end
  else
  begin
    g_pD3DDevice8.DeletePixelShader(Handle);
  end;

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_CreatePixelShader(pFunction: DWORD; pHandle: DWORD): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreatePixelShader' +
    #13#10'(' +
    #13#10'   pFunction          : 0x%.08X' +
    #13#10'   pHandle            : 0x%.08X' +
    #13#10');',
    [pFunction, pHandle]);

  // redirect to windows d3d
  hRet := g_pD3DDevice8.CreatePixelShader(@pFunction, pHandle);

  if (FAILED(hRet)) then
  begin
    pHandle := X_PIXELSHADER_FAKE_HANDLE;
    EmuWarning('We`re lying about the creation of a pixel shader!');
    hRet := D3D_OK;
  end;

  EmuSwapFS(fsXbox);
  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_SetPixelShader(Handle: DWORD; hRet: HRESULT): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  dwHandle: DWORD;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetPixelShader' +
    #13#10'(' +
    #13#10'   Handle            : 0x%.08X' +
    #13#10');',
    [Handle]);

  // redirect to windows d3d
  hRet := D3D_OK;

    // Fake Programmable Pipeline
  if (Handle = X_PIXELSHADER_FAKE_HANDLE) then
  begin
        // programmable pipeline
        (*//*   Commented out by cxbx
        dwHandle := 0;

        if(dwHandle = 0) then
        begin
   // simplest possible pixel shader, simply output the texture input
              Char szDiffusePixelShader[] =
    #13#10'ps.1.0' +
    #13#10'tex t0' +
    #13#10'mov r0, t0';

            LPD3DXBUFFER pShader := 0;
            LPD3DXBUFFER pErrors := 0;

            // assemble the shader
            D3DXAssembleShader(szDiffusePixelShader, strlen(szDiffusePixelShader) - 1, 0, 0, @pShader, @pErrors);

            // create the shader device handle
            hRet := g_pD3DDevice8.CreatePixelShader((DWORD)pShader.GetBufferPointer(), @dwHandle);

            if(FAILED(hRet)) then
                EmuWarning('Could not create pixel shader');
         end;

        if( not FAILED(hRet)) then
            hRet := g_pD3DDevice8.SetPixelShader(dwHandle);

        if(FAILED(hRet)) then
            EmuWarning('Could not set pixel shader!');
        *)//*/

    g_bFakePixelShaderLoaded := TRUE;
  end
    // Fixed Pipeline, or Recompiled Programmable Pipeline
  else if (Handle = 0) then
  begin
    g_bFakePixelShaderLoaded := False;
    g_pD3DDevice8.SetPixelShader(Handle);
  end;

  if (FAILED(hRet)) then
  begin
    EmuWarning('We''re lying about setting a pixel shader!');

    hRet := D3D_OK;
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

{ TODO: Need to be translated to delphi }
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj
(*XTL.X_D3DResource * WINAPI XTL.EmuIDirect3DDevice8_CreateTexture2
(
    UINT                Width,
    UINT                Height,
    UINT                Depth,
    UINT                Levels,
    DWORD               Usage,
    D3DFORMAT           Format,
    D3DRESOURCETYPE     D3DResource
)
begin
    X_D3DTexture *pTexture;

    case(D3DResource) of
    begin
         3: //D3DRTYPE_TEXTURE
            EmuIDirect3DDevice8_CreateTexture(Width, Height, Levels, Usage, Format, D3DPOOL_MANAGED, @pTexture);
         4: //D3DRTYPE_VOLUMETEXTURE
            EmuIDirect3DDevice8_CreateVolumeTexture(Width, Height, Depth, Levels, Usage, Format, D3DPOOL_MANAGED, (X_D3DVolumeTexture)@pTexture);
         5: //D3DRTYPE_CUBETEXTURE
            CxbxKrnlCleanup('Cube textures temporarily not supported!');
        default:
            CxbxKrnlCleanup('D3DResource := %d is not supported!', D3DResource);
     end;

    Result := pTexture;
end;
*)

function XTL_EmuIDirect3DDevice8_CreateTexture: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  (*PCFormat: D3DFORMAT;
  aFormat: D3DFORMAT; *)
  hRet: HRESULT;
(*(
    UINT            Width,
    UINT            Height,
    UINT            Levels,
    DWORD           Usage,
    D3DPOOL         Pool,
    X_D3DTexture  **ppTexture
) *)
begin
  hret := 0;
  EmuSwapFS(fsWindows);

    { TODO -oDxbx: Need to be translated to delphi }
    (*DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateTexture' +
           #13#10'(' +
           #13#10'   Width              : 0x%.08X' +
           #13#10'   Height             : 0x%.08X' +
           #13#10'   Levels             : 0x%.08X' +
           #13#10'   Usage              : 0x%.08X' +
           #13#10'   Format             : 0x%.08X' +
           #13#10'   Pool               : 0x%.08X' +
           #13#10'   ppTexture          : 0x%.08X' +
           #13#10');',
           Width, Height, Levels, Usage, Format, Pool, ppTexture);


    // Convert Format (Xbox->PC)
    PCFormat := XTL_EmuXB2PC_D3DFormat(aFormat);

    // Cxbx TODO: HACK: Devices that don't support this should somehow emulate it!
    //* This is OK on my GeForce FX 5600
  if (PCFormat = D3DFMT_D16) then
  begin
        EmuWarning('D3DFMT_D16 is an unsupported texture format!');
    PCFormat := D3DFMT_R5G6B5;
  end
    //*
  else if (PCFormat = D3DFMT_P8) then
  begin
        EmuWarning('D3DFMT_P8 is an unsupported texture format!');
    PCFormat := D3DFMT_X8R8G8B8;
  end
    //*/
    //* This is OK on my GeForce FX 5600
  else if (PCFormat = D3DFMT_D24S8) then
  begin
        EmuWarning('D3DFMT_D24S8 is an unsupported texture format!');
    PCFormat := D3DFMT_X8R8G8B8;
  end //*/
  else if (PCFormat = D3DFMT_YUY2) then
  begin
        // cache the overlay size
    g_dwOverlayW := Width;
    g_dwOverlayH := Height;
    g_dwOverlayP := RoundUp(g_dwOverlayW, 64) * 2;
  end;



  if (PCFormat <> D3DFMT_YUY2) then
  begin
    DWORD PCUsage := Usage and (D3DUSAGE_RENDERTARGET);
//        DWORD   PCUsage = Usage and (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL);
    D3DPOOL PCPool := D3DPOOL_MANAGED;

    EmuAdjustPower2(@Width, @Height);

    * ppTexture := new X_D3DTexture();

//        if(Usage and (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL))
    if (Usage and (D3DUSAGE_RENDERTARGET)) then
      PCPool := D3DPOOL_DEFAULT;

    hRet = g_pD3DDevice8.CreateTexture
      (
      Width, Height, Levels,
      PCUsage, // Cxbx TODO: Xbox Allows a border to be drawn (maybe hack this in software ;[)
      PCFormat, PCPool, and ((ppTexture).EmuTexture8)
      );

    if (FAILED(hRet)) then
    begin
      EmuWarning('CreateTexture Failed!');
      (ppTexture).Data := $BEADBEAD;
    end
    else
    begin
      D3DLOCKED_RECT LockedRect;

      (ppTexture).EmuTexture8.LockRect(0, @LockedRect, 0, 0);

      (ppTexture).Data := (DWORD)LockedRect.pBits;
      (ppTexture).Format := Format shl X_D3DFORMAT_FORMAT_SHIFT;

      g_DataToTexture.insert((ppTexture).Data, * ppTexture);

      (ppTexture).EmuTexture8.UnlockRect(0);
    end;

    DbgPrintf('EmuD3D8: Created Texture: 0x%.08X (0x%.08X)', [*ppTexture, (ppTexture).EmuTexture8]);
  end
  else
  begin
    DWORD dwSize := g_dwOverlayP * g_dwOverlayH;
    DWORD dwPtr := (DWORD)CxbxMalloc(dwSize + SizeOf(DWORD));

    DWORD * pRefCount := (DWORD)(dwPtr + dwSize);

        // initialize ref count
    * pRefCount := 1;

        // If YUY2 is not supported in hardware, we'll actually mark this as a special fake texture (set highest bit)
    * ppTexture := new X_D3DTexture();

    (ppTexture).Data := X_D3DRESOURCE_DATA_FLAG_SPECIAL or X_D3DRESOURCE_DATA_FLAG_YUVSURF;
    (ppTexture).Lock := dwPtr;
    (ppTexture).Format := $24;

    (ppTexture).Size := (g_dwOverlayW and X_D3DSIZE_WIDTH_MASK);
    (ppTexture).Size := (ppTexture).Size or (g_dwOverlayH shl X_D3DSIZE_HEIGHT_SHIFT);
    (ppTexture).Size := (ppTexture).Size or (g_dwOverlayP shl X_D3DSIZE_PITCH_SHIFT);

    hRet := D3D_OK;
  end;
  *)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_CreateVolumeTexture: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
(*(
    UINT                 Width,
    UINT                 Height,
    UINT                 Depth,
    UINT                 Levels,
    DWORD                Usage,
    D3DFORMAT            Format,
    D3DPOOL              Pool,
    X_D3DVolumeTexture **ppVolumeTexture
) *)
begin
  hret := 0;
  EmuSwapFS(fsWindows);

{ TODO: Need to be translated to delphi }
(*    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateVolumeTexture'
           #13#10'('
           #13#10'   Width              : 0x%.08X'
           #13#10'   Height             : 0x%.08X'
           #13#10'   Depth              : 0x%.08X'
           #13#10'   Levels             : 0x%.08X'
           #13#10'   Usage              : 0x%.08X'
           #13#10'   Format             : 0x%.08X'
           #13#10'   Pool               : 0x%.08X'
           #13#10'   ppVolumeTexture    : 0x%.08X'
           #13#10');',
           Width, Height, Depth, Levels, Usage, Format, Pool, ppVolumeTexture);

    // Convert Format (Xbox->PC)
    D3DFORMAT PCFormat := EmuXB2PC_D3DFormat);

    // Cxbx TODO: HACK: Devices that don't support this should somehow emulate it!
    if(PCFormat = D3DFMT_D16) then
    begin
        EmuWarning('D3DFMT_16 is an unsupported texture format!');
        PCFormat := D3DFMT_X8R8G8B8;
     end;
    else if(PCFormat = D3DFMT_P8) then
    begin
        EmuWarning('D3DFMT_P8 is an unsupported texture format!');
        PCFormat := D3DFMT_X8R8G8B8;
     end;
    else if(PCFormat = D3DFMT_D24S8) then
    begin
        EmuWarning('D3DFMT_D24S8 is an unsupported texture format!');
        PCFormat := D3DFMT_X8R8G8B8;
     end;
    else if(PCFormat = D3DFMT_YUY2) then
    begin
        // cache the overlay size
        g_dwOverlayW := Width;
        g_dwOverlayH := Height;
        g_dwOverlayP := RoundUp(g_dwOverlayW, 64)*2;
     end;

    if(PCFormat <> D3DFMT_YUY2) then
    begin
        EmuAdjustPower2(@Width, @Height);

        *ppVolumeTexture := new X_D3DVolumeTexture();

        hRet = g_pD3DDevice8.CreateVolumeTexture
        (
            Width, Height, Depth, Levels,
            0,  // Cxbx TODO: Xbox Allows a border to be drawn (maybe hack this in software ;[)
            PCFormat, D3DPOOL_MANAGED,  and ((ppVolumeTexture).EmuVolumeTexture8)
        );

        if(FAILED(hRet)) then
            EmuWarning('CreateVolumeTexture Failed not  (0x%.08X)', hRet);

        DbgPrintf('EmuD3D8: Created Volume Texture: 0x%.08X (0x%.08X)', [*ppVolumeTexture, (ppVolumeTexture).EmuVolumeTexture8]);
     end;
    else
    begin
        DWORD dwSize := g_dwOverlayP*g_dwOverlayH;
        DWORD dwPtr := (DWORD)CxbxMalloc(dwSize + SizeOf(DWORD));

        DWORD *pRefCount := (DWORD)(dwPtr + dwSize);

        // initialize ref count
        *pRefCount := 1;

        // If YUY2 is not supported in hardware, we'll actually mark this as a special fake texture (set highest bit)
        (ppVolumeTexture).Data := X_D3DRESOURCE_DATA_FLAG_SPECIAL or X_D3DRESOURCE_DATA_FLAG_YUVSURF;
        (ppVolumeTexture).Lock := dwPtr;
        (ppVolumeTexture).Format := $24;

        (ppVolumeTexture).Size  := (g_dwOverlayW and X_D3DSIZE_WIDTH_MASK);
        (ppVolumeTexture).Size:= (ppVolumeTexture).Size or (g_dwOverlayH shl X_D3DSIZE_HEIGHT_SHIFT);
        (ppVolumeTexture).Size:= (ppVolumeTexture).Size or (g_dwOverlayP shl X_D3DSIZE_PITCH_SHIFT);

        hRet := D3D_OK;
     end;
     *)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_CreateCubeTexture: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
(*(
    UINT                 EdgeLength,
    UINT                 Levels,
    DWORD                Usage,
    D3DFORMAT            Format,
    D3DPOOL              Pool,
    X_D3DCubeTexture  **ppCubeTexture
) *)
begin
  hret := 0;
  EmuSwapFS(fsWindows);

{ TODO: Need to be translated to delphi }
(*    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateCubeTexture'
           #13#10'('
           #13#10'   EdgeLength         : 0x%.08X'
           #13#10'   Levels             : 0x%.08X'
           #13#10'   Usage              : 0x%.08X'
           #13#10'   Format             : 0x%.08X'
           #13#10'   Pool               : 0x%.08X'
           #13#10'   ppCubeTexture      : 0x%.08X'
           #13#10');',
           EdgeLength, Levels, Usage, Format, Pool, ppCubeTexture);

    // Convert Format (Xbox->PC)
    D3DFORMAT PCFormat := EmuXB2PC_D3DFormat);

    // Cxbx TODO: HACK: Devices that don't support this should somehow emulate it!
    if(PCFormat = D3DFMT_D16) then
    begin
        EmuWarning('D3DFMT_16 is an unsupported texture format!');
        PCFormat := D3DFMT_X8R8G8B8;
     end;
    else if(PCFormat = D3DFMT_P8) then
    begin
        EmuWarning('D3DFMT_P8 is an unsupported texture format!');
        PCFormat := D3DFMT_X8R8G8B8;
     end;
    else if(PCFormat = D3DFMT_D24S8) then
    begin
        EmuWarning('D3DFMT_D24S8 is an unsupported texture format!');
        PCFormat := D3DFMT_X8R8G8B8;
     end;
    else if(PCFormat = D3DFMT_YUY2) then
    begin
        CxbxKrnlCleanup('YUV not supported for cube textures');
     end;

    *ppCubeTexture := new X_D3DCubeTexture();

    HRESULT hRet = g_pD3DDevice8.CreateCubeTexture
    (
        EdgeLength, Levels,
        0,  // Cxbx TODO: Xbox Allows a border to be drawn (maybe hack this in software ;[)
        PCFormat, D3DPOOL_MANAGED,  and ((ppCubeTexture).EmuCubeTexture8)
    );

    DbgPrintf('EmuD3D8: Created Cube Texture: 0x%.08X (0x%.08X)', [*ppCubeTexture, (ppCubeTexture).EmuCubeTexture8]);

    if(FAILED(hRet)) then
        EmuWarning('CreateCubeTexture Failed!');
*)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_CreateIndexBuffer: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
(*(
    UINT                 Length,
    DWORD                Usage,
    D3DFORMAT            Format,
    D3DPOOL              Pool,
    X_D3DIndexBuffer   **ppIndexBuffer
) *)
begin
  hret := 0;
  EmuSwapFS(fsWindows);

(*    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateIndexBuffer'
           #13#10'('
           #13#10'   Length             : 0x%.08X'
           #13#10'   Usage              : 0x%.08X'
           #13#10'   Format             : 0x%.08X'
           #13#10'   Pool               : 0x%.08X'
           #13#10'   ppIndexBuffer      : 0x%.08X'
           #13#10');',
           Length, Usage, Format, Pool, ppIndexBuffer);

    *ppIndexBuffer := new X_D3DIndexBuffer();

    hRet = g_pD3DDevice8.CreateIndexBuffer
    (
        Length, 0, D3DFMT_INDEX16, D3DPOOL_MANAGED,  and ((ppIndexBuffer).EmuIndexBuffer8)
    );

    DbgPrintf('EmuD3D8: EmuIndexBuffer8 := 0x%.08X', [(ppIndexBuffer).EmuIndexBuffer8]);

    if(FAILED(hRet)) then
        EmuWarning('CreateIndexBuffer Failed not  (0x%.08X)', hRet);

    //
    // update data ptr
    //

    begin
        BYTE *pData := 0;

        (ppIndexBuffer).EmuIndexBuffer8.Lock(0, Length, @pData, 0);

        (ppIndexBuffer).Data := (DWORD)pData;
     end;
*)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

(*
XTL.X_D3DIndexBuffer * WINAPI XTL.EmuIDirect3DDevice8_CreateIndexBuffer2(UINT Length)
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj
begin
    X_D3DIndexBuffer *pIndexBuffer := 0;

    EmuIDirect3DDevice8_CreateIndexBuffer
    (
        Length,
        0,
        D3DFMT_INDEX16,
        D3DPOOL_MANAGED,
        @pIndexBuffer
    );

    Result := pIndexBuffer;
end;
*)

function XTL_EmuIDirect3DDevice8_SetIndices(
         pIndexData : pX_D3DIndexBuffer;
         BaseVertexIndex : UINT ): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
  chk : Integer;
  pIndexBuffer : IDirect3DIndexBuffer8;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetIndices' +
           #13#10'(' +
           #13#10'   pIndexData         : 0x%.08X' +
           #13#10'   BaseVertexIndex    : 0x%.08X' +
           #13#10');',
           [pIndexData, BaseVertexIndex]);

    { // Commented out by CXBX
    fflush(stdout);
    if(pIndexData <> 0) then
    begin
        chk := 0;
        if(chk++ = 0) then
        begin
            asm Integer 3
         end;
     end;
    }

    hRet := D3D_OK;

    if(pIndexData <> Nil) then
    begin
        g_pIndexBuffer := pIndexData;
        g_dwBaseVertexIndex := BaseVertexIndex;

        // HACK: Halo Hack
        if(pIndexData.Lock = $00840863) then
            pIndexData.Lock := 0;

        EmuVerifyResourceIsRegistered(pIndexData);

        pIndexBuffer := pIndexData.EmuIndexBuffer8;

        if(pIndexData.Lock <> X_D3DRESOURCE_LOCK_FLAG_NOSIZE) then
            hRet := g_pD3DDevice8.SetIndices(pIndexBuffer, BaseVertexIndex);
    end
    else
    begin
        g_pIndexBuffer := Nil;

        hRet := g_pD3DDevice8.SetIndices(Nil, BaseVertexIndex);
     end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_SetTexture(Stage: DWORD;
  pTexture: PX_D3DResource): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pBaseTexture8: IDirect3DBaseTexture8;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTexture' +
    #13#10'(' +
    #13#10'   Stage              : 0x%.08X' +
    #13#10'   pTexture           : 0x%.08X' +
    #13#10');',
    [Stage, pTexture]);

  (*pBaseTexture8 := nil;

  EmuD3DActiveTexture[Stage] := pTexture;

  if (pTexture <> nil) then
  begin
    EmuVerifyResourceIsRegistered(pTexture);

        (*if(IsSpecialResource(pTexture.Data) and (pTexture.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF)) then
        begin
            //
            // NOTE: Cxbx TODO: This is almost a hack! :)
            //

            EmuSwapFS(fsXbox);
            EmuIDirect3DDevice8_EnableOverlay(TRUE);
            EmuIDirect3DDevice8_UpdateOverlay((X_D3DSurface)pTexture, 0, 0, False, 0);
            EmuSwapFS(fsWindows);
         end
        else
        begin
            pBaseTexture8 := pTexture.EmuBaseTexture8;
            (*
            #ifdef _DEBUG_DUMP_TEXTURE_SETTEXTURE
            if(pTexture <> 0 and (pTexture.EmuTexture8 <> 0)) then
            begin
                 Integer dwDumpTexture := 0;

                 szBuffer: array [0..256-1] of Char;

                case(pTexture.EmuResource8.GetType()) of
                begin
                     D3DRTYPE_TEXTURE:
                    begin
                        StrFmt(szBuffer, _DEBUG_DUMP_TEXTURE_SETTEXTURE 'SetTextureNorm - %.03d (0x%.08X).bmp', dwDumpTexture++, pTexture.EmuTexture8);

                        pTexture.EmuTexture8.UnlockRect(0);

                        D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pTexture.EmuTexture8, 0);
                     end;

                     D3DRTYPE_CUBETEXTURE:
                    begin
                        for(Integer face:=0;face<6;face++)
                        begin
                            StrFmt(szBuffer, _DEBUG_DUMP_TEXTURE_SETTEXTURE 'SetTextureCube%d - %.03d (0x%.08X).bmp', face, dwDumpTexture++, pTexture.EmuTexture8);

                            pTexture.EmuCubeTexture8.UnlockRect((D3DCUBEMAP_FACES)face, 0);

                            D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pTexture.EmuTexture8, 0);
                         end;
                     end;
                 end;
             end;
            //endif
         end;

  end;


     IDirect3DTexture8 *pDummyTexture[4] := (0, 0, 0, 0);

    if(pDummyTexture[Stage] = 0) then
    begin
        if(Stage = 0) then
        begin
            if(D3DXCreateTextureFromFile(g_pD3DDevice8, 'C:\dummy1.bmp', @pDummyTexture[Stage]) <> D3D_OK) then
                CxbxKrnlCleanup('Could not create dummy texture!');
         end;
        else if(Stage = 1) then
        begin
            if(D3DXCreateTextureFromFile(g_pD3DDevice8, 'C:\dummy2.bmp', @pDummyTexture[Stage]) <> D3D_OK) then
                CxbxKrnlCleanup('Could not create dummy texture!');
         end;
     end;
    //*/

    (*
     Integer dwDumpTexture := 0;
     szBuffer: array [0..256-1] of Char;
    StrFmt(szBuffer, 'C:\Aaron\Textures\DummyTexture - %.03d (0x%.08X).bmp', dwDumpTexture++, pDummyTexture);
    pDummyTexture.UnlockRect(0);
    D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pDummyTexture, 0);
    //*/

    //HRESULT hRet = g_pD3DDevice8.SetTexture(Stage, pDummyTexture[Stage]);
    HRESULT hRet := g_pD3DDevice8.SetTexture(Stage, (g_iWireframe = 0) ? pBaseTexture8: 0);
                    *)
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

{ TODO: Need to be translated to delphi }

procedure XTL_EmuIDirect3DDevice8_SwitchTexture
  (
  Method: DWORD;
  Data: DWORD;
  Format: DWORD
  ); register;
// Branch:martin  Revision:39 Done:5 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf(DxbxFormat('EmuD3D8: EmuIDirect3DDevice8_SwitchTexture' +
    #13#10'(' +
    #13#10'   Method             : 0x%.08X' +
    #13#10'   Data               : 0x%.08X' +
    #13#10'   Format             : 0x%.08X' +
    #13#10');',
    [Method, Data, Format]));

    (*DWORD StageLookup[] := ( $00081b00, $00081b40, $00081b80, $00081bc0 );
    DWORD Stage := -1;

    for(Integer v:=0;v<4;v++)
    begin
        if(StageLookup[v] = Method) then
        begin
            Stage := v;
         end;
     end;

    if(Stage = -1) then
    begin
        EmuWarning('Unknown Method (0x%.08X)', Method);
     end;
    else
    begin
        //
        // WARNING: Cxbx TODO: Correct reference counting has not been completely verified for this code
        //

        X_D3DTexture *pTexture := (X_D3DTexture )g_DataToTexture.get(Data);

        EmuWarning('Switching Texture 0x%.08X (0x%.08X) @ Stage %d', pTexture, pTexture.EmuBaseTexture8, Stage);

        HRESULT hRet := g_pD3DDevice8.SetTexture(Stage, pTexture.EmuBaseTexture8);

        (*
        if(pTexture.EmuBaseTexture8 <> 0) then
        begin
             Integer dwDumpTexture := 0;

             szBuffer: array [0..255-1] of Char;

            StrFmt(szBuffer, 'C:\Aaron\Textures\0x%.08X-SwitchTexture%.03d.bmp', pTexture, dwDumpTexture++);

            pTexture.EmuTexture8.UnlockRect(0);

            D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pTexture.EmuBaseTexture8, 0);
         end;
        //*/
     end;
     *)

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_GetDisplayMode(pMode: X_D3DDISPLAYMODE): HRESULT;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pPCMode: D3DDISPLAYMODE;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetDisplayMode' +
    #13#10'(' +
    #13#10'   pMode              : 0x%.08X' +
    #13#10');',
    [@pMode]);


    // make adjustments to parameters to make sense with windows d3d
  begin

   { TODO: Need to be translated to delphi }
   (*     D3DDISPLAYMODE *pPCMode = (D3DDISPLAYMODE)pMode; *)

    hRet := g_pD3DDevice8.GetDisplayMode(pPCMode);

        // Convert Format (PC->Xbox)
        { TODO: Need to be translated to delphi }
        (*
        pMode.Format := EmuPC2XB_D3DpPCMode.Format); *)

        // Cxbx TODO: Make this configurable in the future?
    pMode.Flags := $000000A1; // D3DPRESENTFLAG_FIELD | D3DPRESENTFLAG_INTERLACED | D3DPRESENTFLAG_LOCKABLE_BACKBUFFER

    // Cxbx TODO: Retrieve from current CreateDevice settings?
    pMode.Width := 640;
    pMode.Height := 457; // Battlestar Galactica PAL Version
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_Begin(PrimitiveType: X_D3DPRIMITIVETYPE): HRESULT;
// Branch:martin  Revision:39 Done:5 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_Begin' +
    #13#10'(' +
    #13#10'   PrimitiveType      : 0x%.08X' +
    #13#10');',
    [@PrimitiveType]);

{ TODO: Need to be translated to delphi }
(*    if((PrimitiveType <> X_D3DPT_TRIANGLEFAN) and (PrimitiveType <> X_D3DPT_QUADSTRIP) and (PrimitiveType <> X_D3DPT_QUADLIST)) then
        CxbxKrnlCleanup('EmuIDirect3DDevice8_Begin does not support primitive: %d', PrimitiveType);

    g_IVBPrimitiveType := PrimitiveType;

    if(g_IVBTable = 0) then
    begin
        g_IVBTable := (struct XTL::_D3DIVB)CxbxMalloc(SizeOf(XTL::_D3DIVB)*1024);
     end;

    g_IVBTblOffs := 0;
    g_IVBFVF := 0;

    // default values
    ZeroMemory(g_IVBTable, SizeOf(XTL::_D3DIVB)*1024);

    if(g_pIVBVertexBuffer = 0) then
    begin
        g_pIVBVertexBuffer := (DWORD)CxbxMalloc(SizeOf(XTL::_D3DIVB)*1024);
     end;
*)
  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

function XTL_EmuIDirect3DDevice8_SetVertexData2f(aRegister: Integer; a: FLOAT; b: FLOAT): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  // debug trace
{$IFDEF _DEBUG_TRACE}
  begin
    EmuSwapFS(fsWindows);
    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexData2f  shr ' +
      #13#10'(' +
      #13#10'   Register           : 0x%.08X' +
      #13#10'   a                  : %f' +
      #13#10'   b                  : %f' +
      #13#10');',
      [aRegister, a, b]);
    EmuSwapFS(fsXbox);
  end;
{$ENDIF}
  Result := XTL_EmuIDirect3DDevice8_SetVertexData4f(aRegister, a, b, 0.0, 1.0);
end;


function FtoDW(f: FLOAT): DWORD;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  Result := Round(f);
end;

function DWtoF(f: DWORD): FLOAT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  Result := f;
end;


function XTL_EmuIDirect3DDevice8_SetVertexData2s(aRegister: Integer; a: SmallInt; b: SmallInt): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  DwA, dwB: DWORD;
begin
    // debug trace
{$IFDEF _DEBUG_TRACE}
  begin
    EmuSwapFS(fsWindows);
    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexData2s  shr ' +
      #13#10'(' +
      #13#10'   Register           : 0x%.08X' +
      #13#10'   a                  : %d' +
      #13#10'   b                  : %d' +
      #13#10');',
      [aRegister, a, b]);
    EmuSwapFS(fsXbox);
  end;
{$ENDIF}

  dwA := a;
  dwB := b;

  Result := XTL_EmuIDirect3DDevice8_SetVertexData4f(aRegister, DWtoF(dwA), DWtoF(dwB), 0.0, 1.0);
end;

function XTL_EmuIDirect3DDevice8_SetVertexData4f(aRegister: Integer;
  a, b, c, d: FLOAT): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
(*  o: Integer;*)
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexData4f' +
    #13#10'(' +
    #13#10'   Register           : 0x%.08X' +
    #13#10'   a                  : %f' +
    #13#10'   b                  : %f' +
    #13#10'   c                  : %f' +
    #13#10'   d                  : %f' +
    #13#10');',
    [aRegister, a, b, c, d]);

  hRet := S_OK;

  case (aRegister) of
    0: // D3DVSDE_POSITION
      begin
        (*o := g_IVBTblOffs;
        g_IVBTable[o].Position.x := a; //vertices[o*2+0];//a;
        g_IVBTable[o].Position.y := b; //vertices[o*2+1];//b;
        g_IVBTable[o].Position.z := c;
        g_IVBTable[o].Rhw := 1.0;

        g_IVBTblOffs := g_IVBTblOffs + 1;

        g_IVBFVF := g_IVBFVF or D3DFVF_XYZRHW; *)
      end;

    3: // D3DVSDE_DIFFUSE
      begin
        (*o := g_IVBTblOffs;
        DWORD ca := FtoDW(d) shl 24;
        DWORD cr := FtoDW(a) shl 16;
        DWORD cg := FtoDW(b) shl 8;
        DWORD cb := FtoDW(c) shl 0;

        g_IVBTable[o].dwDiffuse := ca or cr or cg or cb;

        g_IVBFVF := g_IVBFVF or D3DFVF_DIFFUSE; *)
      end;

    4: // D3DVSDE_SPECULAR
      begin
        (*o := g_IVBTblOffs;
        DWORD ca := FtoDW(d) shl 24;
        DWORD cr := FtoDW(a) shl 16;
        DWORD cg := FtoDW(b) shl 8;
        DWORD cb := FtoDW(c) shl 0;

        g_IVBTable[o].dwSpecular := ca or cr or cg or cb;

        g_IVBFVF := g_IVBFVF or D3DFVF_SPECULAR; *)
      end;

    9: // D3DVSDE_TEXCOORD0
      begin
        (*Integer o := g_IVBTblOffs;
            {
            if(a > 640) then  a := 640;
            if(b > 480) then  b := 480;

            if(a > 1.0f) then  a:= a div 640.0f;
            if(b > 1.0f) then  b:= b div 480.0f;
            }
        g_IVBTable[o].TexCoord1.x := a;
        g_IVBTable[o].TexCoord1.y := b;

        if ((g_IVBFVF and D3DFVF_TEXCOUNT_MASK) < D3DFVF_TEX1) then
        begin
          g_IVBFVF := g_IVBFVF or D3DFVF_TEX1;
        end;
        *)
      end;

    10: // D3DVSDE_TEXCOORD1
      begin
        (*
        Integer o := g_IVBTblOffs;
            {
            if(a > 640) then  a := 640;
            if(b > 480) then  b := 480;

            if(a > 1.0f) then  a:= a div 640.0f;
            if(b > 1.0f) then  b:= b div 480.0f;
            }
        g_IVBTable[o].TexCoord2.x := a;
        g_IVBTable[o].TexCoord2.y := b;

        if ((g_IVBFVF and D3DFVF_TEXCOUNT_MASK) < D3DFVF_TEX2) then
        begin
          g_IVBFVF := g_IVBFVF or D3DFVF_TEX2;
        end;
        *)
      end;

    11: // D3DVSDE_TEXCOORD2
      begin
        (*
        Integer o := g_IVBTblOffs;
            {
            if(a > 640) then  a := 640;
            if(b > 480) then  b := 480;

            if(a > 1.0f) then  a:= a div 640.0f;
            if(b > 1.0f) then  b:= b div 480.0f;
            }
        g_IVBTable[o].TexCoord3.x := a;
        g_IVBTable[o].TexCoord3.y := b;

        if ((g_IVBFVF and D3DFVF_TEXCOUNT_MASK) < D3DFVF_TEX3) then
        begin
          g_IVBFVF := g_IVBFVF or D3DFVF_TEX3;
        end;
        *)
      end;

    12: // D3DVSDE_TEXCOORD3
      begin
        (*
        Integer o := g_IVBTblOffs;
            {
            if(a > 640) then  a := 640;
            if(b > 480) then  b := 480;

            if(a > 1.0f) then  a:= a div 640.0f;
            if(b > 1.0f) then  b:= b div 480.0f;
            }
        g_IVBTable[o].TexCoord4.x := a;
        g_IVBTable[o].TexCoord4.y := b;

        if ((g_IVBFVF and D3DFVF_TEXCOUNT_MASK) < D3DFVF_TEX4) then
        begin
          g_IVBFVF := g_IVBFVF or D3DFVF_TEX4;
        end;
        *)
      end;

    (*
    $FFFFFFFF:
    begin
      Integer o := g_IVBTblOffs;

          {
          a := (a*320.0f) + 320.0f;
          b := (b*240.0f) + 240.0f;
          }

      g_IVBTable[o].Position.x := a; //vertices[o*2+0];//a;
      g_IVBTable[o].Position.y := b; //vertices[o*2+1];//b;
      g_IVBTable[o].Position.z := c;
      g_IVBTable[o].Rhw := 1.0 f;

      g_IVBTblOffs := g_IVBTblOffs + 1;

      g_IVBFVF := g_IVBFVF or D3DFVF_XYZRHW;
    end;
    *)

  else
    CxbxKrnlCleanup('Unknown IVB Register: %d', [aRegister]);
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_SetVertexDataColor(aRegister: Integer; Color: D3DCOLOR): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  a: FLOAT;
  r: FLOAT;
  g: FLOAT;
  b: FLOAT;
begin
  // debug trace
{$IFDEF _DEBUG_TRACE}

  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexDataColor  shr ' +
    #13#10'(' +
    #13#10'   Register           : 0x%.08X' +
    #13#10'   Color              : 0x%.08X' +
    #13#10');',
    [aRegister, Color]);
  EmuSwapFS(fsXbox);
{$ENDIF}

  a := DWtoF((Color and $FF000000) shr 24);
  r := DWtoF((Color and $00FF0000) shr 16);
  g := DWtoF((Color and $0000FF00) shr 8);
  b := DWtoF((Color and $000000FF) shr 0);

  Result := XTL_EmuIDirect3DDevice8_SetVertexData4f(aRegister, r, g, b, a);
end;

function XTL_EmuIDirect3DDevice8_End: HRESULT; stdcall;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_End();');

    { TODO -oDxbx: Need to be translated to delphi }
    (*if(g_IVBTblOffs <> 0) then
        EmuFlushIVB();
    *)

    // Cxbx TODO: Should technically clean this up at some point..but on XP doesnt matter much
//    CxbxFree(g_pIVBVertexBuffer);
//    CxbxFree(g_IVBTable);

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

procedure XTL_EmuIDirect3DDevice8_RunPushBuffer(pPushBuffer: PX_D3DPushBuffer;
  pFixup: PX_D3DFixup); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_RunPushBuffer' +
    #13#10'(' +
    #13#10'   pPushBuffer        : 0x%.08X' +
    #13#10'   pFixup             : 0x%.08X' +
    #13#10');',
    [pPushBuffer, pFixup]);

  XTL_EmuExecutePushBuffer(pPushBuffer, pFixup);

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_Clear(Count : DWORD;
    pRects : pD3DRECT;
    Flags : DWORD;
    Color : D3DCOLOR;
    Z : Single;
    Stencil : DWORD): HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  ret: HRESULT;
  newFlags : DWORD;
begin
  ret := 0;
  EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_Clear'+
           #13#10'(' +
           #13#10'   Count              : 0x%.08X' +
           #13#10'   pRects             : 0x%.08X' +
           #13#10'   Flags              : 0x%.08X' +
           #13#10'   Color              : 0x%.08X' +
           #13#10'   Z                  : %f' +
           #13#10'   Stencil            : 0x%.08X' +
           #13#10');',
           [Count, pRects, Flags,
           Color, Z, Stencil]);

    // make adjustments to parameters to make sense with windows d3d
    (*begin
        // Cxbx TODO: D3DCLEAR_TARGET_A, *R, *G, *B don't exist on windows
        newFlags := 0;

        if(Flags and $000000f0) then
            newFlags:= newFlags or D3DCLEAR_TARGET;

        if(Flags and $00000001) then
            newFlags:= newFlags or D3DCLEAR_ZBUFFER;

        if(Flags and $00000002) then
            newFlags:= newFlags or D3DCLEAR_STENCIL;

        if(Flags and ~($000000f0 or $00000001 or $00000002)) then
            EmuWarning('Unsupported Flag(s) for IDirect3DDevice8_Clear: 0x%.08X', Flags and ~($000000f0 or $00000001 or $00000002));

        Flags := newFlags;
     end;

    HRESULT ret := g_pD3DDevice8.Clear(Count, pRects, Flags, Color, Z, Stencil);
*)
  EmuSwapFS(fsXbox);

  Result := ret;
end;

function XTL_EmuIDirect3DDevice8_Present: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  hRet: HRESULT;
(*(
    CONST TRect* pSourceRect,
    CONST TRect* pDestRect,
    PVOID       pDummy1,
    PVOID       pDummy2
) *)
begin
  hret := 0;
  EmuSwapFS(fsWindows);

{ TODO: Need to be translated to delphi }
(*    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_Present'
           #13#10'('
           #13#10'   pSourceRect        : 0x%.08X'
           #13#10'   pDestRect          : 0x%.08X'
           #13#10'   pDummy1            : 0x%.08X'
           #13#10'   pDummy2            : 0x%.08X'
           #13#10');',
           pSourceRect, pDestRect, pDummy1, pDummy2);

    // release back buffer lock
    begin
        IDirect3DSurface8 *pBackBuffer;

        g_pD3DDevice8.GetBackBuffer(0, D3DBACKBUFFER_TYPE_MONO, @pBackBuffer);

        pBackBuffer.UnlockRect();
     end;

    HRESULT hRet := g_pD3DDevice8.Present(pSourceRect, pDestRect, (HWND)pDummy1, (CONST RGNDATA)pDummy2);

    // not really accurate because you definately dont always present on every vblank
    g_VBData.Swap := g_VBData.VBlank;

    if(g_VBData.VBlank = g_VBLastSwap + 1) then
        g_VBData.Flags := 1; // D3DVBLANK_SWAPDONE
    else
        g_VBData.Flags := 2; // D3DVBLANK_SWAPMISSED
*)
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_Swap(Flags: DWORD): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pBackBuffer: IDirect3DSurface8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_Swap' +
    #13#10'(' +
    #13#10'   Flags              : 0x%.08X' +
    #13#10');',
    [Flags]);

  // Cxbx TODO: Ensure this flag is always the same across library versions
  if (Flags <> 0) then
    EmuWarning('XTL.EmuIDirect3DDevice8_Swap: Flags <> 0');

  // release back buffer lock
  begin
    g_pD3DDevice8.GetBackBuffer(0, D3DBACKBUFFER_TYPE_MONO, pBackBuffer);

    pBackBuffer.UnlockRect();
  end;

  hRet := g_pD3DDevice8.Present(nil, nil, 0, nil);
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DResource8_Register(pThis: PX_D3DResource; pBase: PVOID): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pResource: PX_D3DResource;
  dwCommonType: DWORD;
  pIndexBuffer : pX_D3DIndexBuffer;
  pVertexBuffer: PX_D3DVertexBuffer;
  pPushBuffer: PX_D3DPushBuffer;
  pPixelContainer: PX_D3DPixelContainer;
  pFixup: PX_D3DFixup;
  dwSize: DWORD;
  pData: PBYTE;
  X_Format : X_D3DFORMAT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DResource8_Register' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X (.Data: 0x%.08X)' +
    #13#10'   pBase              : 0x%.08X' +
    #13#10');',
    [pThis, pThis.Data, pBase]);

  hRet := S_OK;

  pResource := pThis;

  dwCommonType := pResource.Common and X_D3DCOMMON_TYPE_MASK;

  // add the offset of the current texture to the base
  pBase := PVOID(DWORD(pBase) + pThis.Data);

  // Determine the resource type, and initialize
  case dwCommonType of

    X_D3DCOMMON_TYPE_VERTEXBUFFER:
    begin
      DbgPrintf('EmuIDirect3DResource8_Register : Creating VertexBuffer...');

      pVertexBuffer := PX_D3DVertexBuffer(pResource);

      // create vertex buffer
      dwSize := EmuCheckAllocationSize(pBase, True);

      if dwSize = DWORD(-1) then
      begin
        // Cxbx TODO: once this is known to be working, remove the warning
        EmuWarning('Vertex buffer allocation size unknown');
        dwSize := $2000; // temporarily assign a small buffer, which will be increased later
      end;

      (*hRet := g_pD3DDevice8.CreateVertexBuffer(
          {Length=}dwSize,
          {Usage=}0,
          {FVF=}0,
          {Pool=}D3DPOOL_MANAGED,
          {out ppVertexBuffer=}pResource.EmuVertexBuffer8);
      // IDirect3DVertexBuffer8 *)

{$IFDEF _DEBUG_TRACK_VB}
      g_VBTrackTotal.insert(pResource.EmuVertexBuffer8);
{$ENDIF}

      pData := Nil;

      hRet := pResource.EmuVertexBuffer8.Lock(0, 0, pData, 0);

      if FAILED(hRet) then
        CxbxKrnlCleanup('VertexBuffer Lock Failed!');

      Move(pBase, pData, dwSize);

      pResource.EmuVertexBuffer8.Unlock();

      pResource.Data := ULONG(pData);

      DbgPrintf('EmuIDirect3DResource8_Register : Successfully Created VertexBuffer (0x%.08X)', [pResource.EmuVertexBuffer8]);

    end;


    X_D3DCOMMON_TYPE_INDEXBUFFER:
    begin
      DbgPrintf('EmuIDirect3DResource8_Register :. IndexBuffer...');
      pIndexBuffer := pX_D3DIndexBuffer(pResource);

      // create index buffer
      begin
        dwSize := EmuCheckAllocationSize(pBase, True);

        if (dwSize = -1) then
        begin
          // Cxbx TODO: once this is known to be working, remove the warning
          EmuWarning('Index buffer allocation size unknown');

          pIndexBuffer.Lock := X_D3DRESOURCE_LOCK_FLAG_NOSIZE;

          Exit;
          // Halo dwSize = 0x336;
        end;

        (*hRet := g_pD3DDevice8.CreateIndexBuffer(
          dwSize, 0, D3DFMT_INDEX16, D3DPOOL_MANAGED,
          @pIndexBuffer.EmuIndexBuffer8
          ); *)

        if (FAILED(hRet)) then
          CxbxKrnlCleanup('CreateIndexBuffer Failed!');

        pData := Nil;

        hRet := pResource.EmuIndexBuffer8.Lock(0, dwSize, pData, 0);

        if (FAILED(hRet)) then
          CxbxKrnlCleanup('IndexBuffer Lock Failed!');

        Move(pBase, pData, dwSize);

        pResource.EmuIndexBuffer8.Unlock();

        pResource.Data := ULONG(pData);
      end;

      DbgPrintf('EmuIDirect3DResource8_Register : Successfully Created IndexBuffer (0x%.08X)', [pResource.EmuIndexBuffer8]);
    end;


    X_D3DCOMMON_TYPE_PUSHBUFFER:
    begin
      DbgPrintf('EmuIDirect3DResource8_Register : PushBufferArgs...');

      pPushBuffer := PX_D3DPushBuffer(pResource);

      // create push buffer
      dwSize := EmuCheckAllocationSize(pBase, True);

      if dwSize = DWORD(-1) then
      begin
        // Cxbx TODO: once this is known to be working, remove the warning
        EmuWarning('Push buffer allocation size unknown');

        pPushBuffer.Lock := X_D3DRESOURCE_LOCK_FLAG_NOSIZE;
      end
      else
      begin
        pResource.Data := ULONG(pBase);

        DbgPrintf('EmuIDirect3DResource8_Register : Successfully Created PushBuffer (0x%.08X, 0x%.08X, 0x%.08X)', [pResource.Data, pPushBuffer.Size, pPushBuffer.AllocationSize]);
      end;
    end;


    (*X_D3DCOMMON_TYPE_SURFACE,
    X_D3DCOMMON_TYPE_TEXTURE:
    begin
      if (dwCommonType = X_D3DCOMMON_TYPE_SURFACE) then
        DbgPrintf('EmuIDirect3DResource8_Register :. Surface...')
      else
        DbgPrintf('EmuIDirect3DResource8_Register :. Texture...');


      pPixelContainer := pX_D3DPixelContainer(pResource);

      (*X_Format := (X_D3DFORMAT)((pPixelContainer.Format and X_D3DFORMAT_FORMAT_MASK) shr X_D3DFORMAT_FORMAT_SHIFT);
      D3DFORMAT Format := EmuXB2PC_D3DX_Format);

      D3DFORMAT CacheFormat;
      // Cxbx TODO: check for dimensions

      // Cxbx TODO: HACK: Temporary?
      if (X_Format = $2E) then
      begin
        CxbxKrnlCleanup('D3DFMT_LIN_D24S8 not yet supported!');
        X_Format := $12;
        Format := D3DFMT_A8R8G8B8;
      end;

      DWORD dwWidth, dwHeight, dwBPP, dwDepth := 1, dwPitch = 0, dwMipMapLevels = 1;
      BOOL bSwizzled := False, bCompressed = False, dwCompressedSize = 0;
      BOOL bCubemap := pPixelContainer.Format and X_D3DFORMAT_CUBEMAP;

      // Interpret Width/Height/BPP
      (*
      if(X_Format = $07 (* X_D3DFMT_X8R8G8B8 *)(*|| X_Format == 0x06 /* X_D3DFMT_A8R8G8B8 */) then
      begin
        bSwizzled := TRUE;

        // Swizzled 32 Bit
        dwWidth  := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_USIZE_MASK) shr X_D3DFORMAT_USIZE_SHIFT);
        dwHeight := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_VSIZE_MASK) shr X_D3DFORMAT_VSIZE_SHIFT);
        dwMipMapLevels := (pPixelContainer.Format and X_D3DFORMAT_MIPMAP_MASK) shr X_D3DFORMAT_MIPMAP_SHIFT;
        dwDepth  := 1;// HACK? 1 << ((pPixelContainer.Format and X_D3DFORMAT_PSIZE_MASK) >> X_D3DFORMAT_PSIZE_SHIFT);
        dwPitch  := dwWidth*4;
        dwBPP := 4;
      end
      else if(X_Format = $05 (* X_D3DFMT_R5G6B5 *)(*then  || X_Format == 0x04 /* X_D3DFMT_A4R4G4B4 */
             or X_Format = $1D (* X_D3DFMT_LIN_A4R4G4B4 *)(*|| X_Format == 0x02 /* X_D3DFMT_A1R5G5B5 */
             or X_Format = $28 (* X_D3DFMT_G8B8 *)//)
      (*begin
        bSwizzled := TRUE;

        // Swizzled 16 Bit
        dwWidth  := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_USIZE_MASK) shr X_D3DFORMAT_USIZE_SHIFT);
        dwHeight := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_VSIZE_MASK) shr X_D3DFORMAT_VSIZE_SHIFT);
        dwMipMapLevels := (pPixelContainer.Format and X_D3DFORMAT_MIPMAP_MASK) shr X_D3DFORMAT_MIPMAP_SHIFT;
        dwDepth  := 1;// HACK? 1 << ((pPixelContainer.Format and X_D3DFORMAT_PSIZE_MASK) >> X_D3DFORMAT_PSIZE_SHIFT);
        dwPitch  := dwWidth*2;
        dwBPP := 2;
      end
      else if(X_Format = $00 (* X_D3DFMT_L8 *)(*|| X_Format == 0x0B /* X_D3DFMT_P8 */ || X_Format == 0x01 /* X_D3DFMT_AL8 */ || X_Format == 0x1A /* X_D3DFMT_A8L8 */) then
      begin
        bSwizzled := TRUE;

        // Swizzled 8 Bit
        dwWidth  := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_USIZE_MASK) shr X_D3DFORMAT_USIZE_SHIFT);
        dwHeight := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_VSIZE_MASK) shr X_D3DFORMAT_VSIZE_SHIFT);
        dwMipMapLevels := (pPixelContainer.Format and X_D3DFORMAT_MIPMAP_MASK) shr X_D3DFORMAT_MIPMAP_SHIFT;
        dwDepth  := 1;// HACK? 1 << ((pPixelContainer.Format and X_D3DFORMAT_PSIZE_MASK) >> X_D3DFORMAT_PSIZE_SHIFT);
        dwPitch  := dwWidth;
        dwBPP := 1;
      end
      else if(X_Format = $1E (* X_D3DFMT_LIN_X8R8G8B8 *)(*|| X_Format == 0x12 /* X_D3DFORMAT_A8R8G8B8 */ || X_Format == 0x2E /* D3DFMT_LIN_D24S8 */) then
      begin
        // Linear 32 Bit
        dwWidth  := (pPixelContainer.Size and X_D3DSIZE_WIDTH_MASK) + 1;
        dwHeight := ((pPixelContainer.Size and X_D3DSIZE_HEIGHT_MASK) shr X_D3DSIZE_HEIGHT_SHIFT) + 1;
        dwPitch  := (((pPixelContainer.Size and X_D3DSIZE_PITCH_MASK) shr X_D3DSIZE_PITCH_SHIFT)+1)*64;
        dwBPP := 4;
      end
      else if(X_Format = $11 (* D3DFMT_LIN_R5G6B5 *)(*)then
      begin
        // Linear 16 Bit
        dwWidth := (pPixelContainer.Size and X_D3DSIZE_WIDTH_MASK) + 1;
        dwHeight := ((pPixelContainer.Size and X_D3DSIZE_HEIGHT_MASK) shr X_D3DSIZE_HEIGHT_SHIFT) + 1;
        dwPitch := (((pPixelContainer.Size and X_D3DSIZE_PITCH_MASK) shr X_D3DSIZE_PITCH_SHIFT) + 1) * 64;
        dwBPP := 2;
      end
      else if (X_Format = $0C (* D3DFMT_DXT1 *) (*|| X_Format == 0x0E /* D3DFMT_DXT2 */ || X_Format == 0x0F /* D3DFMT_DXT3 */) then
      begin
        bCompressed := TRUE;

        // Compressed
        dwWidth  := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_USIZE_MASK) shr X_D3DFORMAT_USIZE_SHIFT);
        dwHeight := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_VSIZE_MASK) shr X_D3DFORMAT_VSIZE_SHIFT);
        dwDepth  := 1 shl ((pPixelContainer.Format and X_D3DFORMAT_PSIZE_MASK) shr X_D3DFORMAT_PSIZE_SHIFT);
        dwMipMapLevels := (pPixelContainer.Format and X_D3DFORMAT_MIPMAP_MASK) shr X_D3DFORMAT_MIPMAP_SHIFT;

        // D3DFMT_DXT2...D3DFMT_DXT5: 128bits per block/per 16 texels
        dwCompressedSize := dwWidth*dwHeight;

        if(X_Format = $0C) then     // D3DFMT_DXT1: 64bits per block/per 16 texels
          dwCompressedSize:= dwCompressedSize div 2;

        dwBPP := 1;
      end
      else if(X_Format = $24 (* D3DFMT_YUY2 *)(*)then
      begin
        // Linear 32 Bit
        dwWidth := (pPixelContainer.Size and X_D3DSIZE_WIDTH_MASK) + 1;
        dwHeight := ((pPixelContainer.Size and X_D3DSIZE_HEIGHT_MASK) shr X_D3DSIZE_HEIGHT_SHIFT) + 1;
        dwPitch := (((pPixelContainer.Size and X_D3DSIZE_PITCH_MASK) shr X_D3DSIZE_PITCH_SHIFT) + 1) * 64;
      end
      else
      begin
        CxbxKrnlCleanup('0x%.08 X is not a supported format!', X_Format);
      end;

      if (X_Format = $24 (* X_D3DFMT_YUY2 *) (*) then
      begin
        //
        // cache the overlay size
        //

        g_dwOverlayW := dwWidth;
        g_dwOverlayH := dwHeight;
        g_dwOverlayP := RoundUp(g_dwOverlayW, 64) * 2;

        //
        // create texture resource
        //

        DWORD dwSize := g_dwOverlayP * g_dwOverlayH;
        DWORD dwPtr := (DWORD)CxbxMalloc(dwSize + SizeOf(DWORD));

        DWORD * pRefCount := (DWORD)(dwPtr + dwSize);

                // initialize ref count
        * pRefCount := 1;

                // If YUY2 is not supported in hardware, we'll actually mark this as a special fake texture (set highest bit)
        pPixelContainer.Data := X_D3DRESOURCE_DATA_FLAG_SPECIAL or X_D3DRESOURCE_DATA_FLAG_YUVSURF;
        pPixelContainer.Lock := dwPtr;
        pPixelContainer.Format := $24;

        pPixelContainer.Size := (g_dwOverlayW and X_D3DSIZE_WIDTH_MASK);
        pPixelContainer.Size := pPixelContainer.Size or (g_dwOverlayH shl X_D3DSIZE_HEIGHT_SHIFT);
        pPixelContainer.Size := pPixelContainer.Size or (g_dwOverlayP shl X_D3DSIZE_PITCH_SHIFT);
      end
      else
      begin
        if (bSwizzled or bCompressed) then
        begin
          uint32 w := dwWidth;
          uint32 h := dwHeight;

          for (uint32 v := 0; v < dwMipMapLevels; v++)
          begin
            if (((1 u shl v) >= w) or ((1 u shl v) >= h)) then
            begin
              dwMipMapLevels := v + 1;
              Break;
            end;
          end;
        end;

        // create the happy little texture
        if (dwCommonType = X_D3DCOMMON_TYPE_SURFACE) then
        begin
          hRet := g_pD3DDevice8.CreateImageSurface(dwWidth, dwHeight, Format, @pResource.EmuSurface8);

          if (FAILED(hRet)) then
            CxbxKrnlCleanup('CreateImageSurface Failed!');

          DbgPrintf('EmuIDirect3DResource8_Register: Successfully Created ImageSurface(0x%.08X, 0x%.08X)', [pResource, pResource.EmuSurface8]);
          DbgPrintf('EmuIDirect3DResource8_Register: Width:%d, Height:%d, Format:%d', [dwWidth, dwHeight, Format]);
        end
        else
        begin
          // Cxbx TODO: HACK: Figure out why this is necessary!
          // Cxbx TODO: This is necessary for DXT1 textures at least (4x4 blocks minimum)
          if (dwWidth < 4) then
          begin
            EmuWarning('Expanding texture width(mod d.4)', dwWidth);
            dwWidth := 4;

            dwMipMapLevels := 3;
          end;

          if (dwHeight < 4) then
          begin
            EmuWarning('Expanding texture height(mod d.4)', dwHeight);
            dwHeight := 4;

            dwMipMapLevels := 3;
          end;

          // HACK HACK HACK HACK HACK HACK HACK HACK HACK HACK
          // Since most modern graphics cards does not support
          // palette based textures we need to expand it to
          // ARGB texture format
          if (Format = D3DFMT_P8) then //Palette
          begin
            CacheFormat := Format; // Save this for later
            Format := D3DFMT_A8R8G8B8; // ARGB
          end;

          if (bCubemap) then
          begin
            DbgPrintf('CreateCubeTexture(%d,%d, 0,%d, D3DPOOL_MANAGED, 0x%.08X)',
              [dwWidth, dwMipMapLevels, Format, @pResource.EmuTexture8]);

            hRet = g_pD3DDevice8.CreateCubeTexture
              (
              dwWidth, dwMipMapLevels, 0, Format,
              D3DPOOL_MANAGED, @pResource.EmuCubeTexture8
              );

            if (FAILED(hRet)) then
              CxbxKrnlCleanup('CreateCubeTexture Failed!');

            DbgPrintf('EmuIDirect3DResource8_Register: Successfully Created CubeTexture(0x%.08 X, 0x%.08 X)', [pResource, pResource.EmuCubeTexture8]);
          end
          else
          begin
            DbgPrintf('CreateTexture(%d,%d,%d, 0,%d, D3DPOOL_MANAGED, 0x%.08X)',
              [dwWidth, dwHeight, dwMipMapLevels, Format, @pResource.EmuTexture8]);

            hRet = g_pD3DDevice8.CreateTexture
              (
              dwWidth, dwHeight, dwMipMapLevels, 0, Format,
              D3DPOOL_MANAGED, @pResource.EmuTexture8
              );

            if (FAILED(hRet)) then
              CxbxKrnlCleanup('CreateTexture Failed!');


            DbgPrintf('EmuIDirect3DResource8_Register: Successfully Created Texture(0x%.08 X, 0x%.08 X)', [pResource, pResource.EmuTexture8]); * )
          end;

        end;

uint32 stop := bCubemap ? 6: 1;

for (uint32 r := 0; r < stop; r++)
begin
                  // as we iterate through mipmap levels, we'll adjust the source resource offset
DWORD dwCompressedOffset := 0;

DWORD dwMipOffs := 0;
DWORD dwMipWidth := dwWidth;
DWORD dwMipHeight := dwHeight;
DWORD dwMipPitch := dwPitch;

                  // iterate through the number of mipmap levels
for (uint level := 0; level < dwMipMapLevels; level++)
begin
  D3DLOCKED_RECT LockedRect;

                      // copy over data (deswizzle if necessary)
  if (dwCommonType = X_D3DCOMMON_TYPE_SURFACE) then
    hRet := pResource.EmuSurface8.LockRect(@LockedRect, 0, 0)
  else
  begin
    if (bCubemap) then
    begin
      hRet := pResource.EmuCubeTexture8.LockRect((D3DCUBEMAP_FACES)r, 0, @LockedRect, 0, 0);
    end
    else
    begin
      hRet := pResource.EmuTexture8.LockRect(level, @LockedRect, 0, 0);
    end;
  end;

  TRect iRect := (0, 0, 0, 0);
  TPoint iPoint := (0, 0);

  BYTE * pSrc := (BYTE)pBase;

  pThis.Data := (DWORD)pSrc;

  if ((IsSpecialResource(pResource.Data) and (pResource.Data and X_D3DRESOURCE_DATA_FLAG_SURFACE)) then
    or (IsSpecialResource(pBase) and ((DWORD)pBase and X_D3DRESOURCE_DATA_FLAG_SURFACE)))
  begin
    EmuWarning('Attempt to registered to another resource' s data(eww not )');

      // Cxbx TODO: handle this horrible situation
      BYTE * pDest := (BYTE)LockedRect.pBits;
      for (DWORD v := 0; v < dwMipHeight; v++)
      begin
        FillChar(pDest, 0, dwMipWidth * dwBPP);

        pDest := pDest + LockedRect.Pitch;
        pSrc := pSrc + dwMipPitch;
      end;
  end
else
begin
  if (bSwizzled) then
  begin
    if ((DWORD)pSrc = $80000000) then
    begin
      // Cxbx TODO: Fix or handle this situation..?
    end
    else
    begin
      if (CacheFormat = D3DFMT_P8) then //Palette
      begin
        EmuWarning('Unsupported texture format D3DFMT_P8, expanding to D3DFMT_A8R8G8B8');

        //
        // create texture resource
        //
        BYTE * pPixelData := (BYTE)LockedRect.pBits;
        DWORD dwDataSize := dwMipWidth * dwMipHeight * 4;
        DWORD dwPaletteSize := 256 * 4; // Note: This is not allways true, it can be 256- 128- 64- or 32*4

        BYTE * pTextureCache := (BYTE)CxbxMalloc(dwDataSize);
        BYTE * pExpandedTexture := (BYTE)CxbxMalloc(dwDataSize);
        BYTE * pTexturePalette := (BYTE)CxbxMalloc(256 * 4);

        // First we need to unswizzle the texture data
        XTL.EmuXGUnswizzleRect
          (
          pSrc + dwMipOffs, dwMipWidth, dwMipHeight, dwDepth, LockedRect.pBits,
          LockedRect.Pitch, iRect, iPoint, dwBPP
          );

        // Copy the unswizzled data to a temporary buffer
        Move(pPixelData, pTextureCache, dwDataSize);

        // Copy the currently selected palette's data to the buffer
        Move(pCurrentPalette, pTexturePalette, dwPaletteSize);

        Word w := 0;
        Word c := 0;
        Byte p := 0;
        for (Word y := 0; y < dwDataSize / 4; y++)
        begin
          if (c = dwMipWidth) then
          begin
            w := w + dwMipWidth * 3;
            c := 0;
          end;
          p := (Byte)pTextureCache[w];
          pExpandedTexture[y * 4 + 0] := pTexturePalette[p * 4 + 0];
          pExpandedTexture[y * 4 + 1] := pTexturePalette[p * 4 + 1];
          pExpandedTexture[y * 4 + 2] := pTexturePalette[p * 4 + 2];
          pExpandedTexture[y * 4 + 3] := pTexturePalette[p * 4 + 3];
          w := w + 1;
          c := c + 1;
        end;

        // Copy the expanded texture back to the buffer
        Move(pExpandedTexture, pPixelData, dwDataSize);

        // Flush unused data buffers
        CxbxFree(pTexturePalette);
        CxbxFree(pExpandedTexture);
        CxbxFree(pTextureCache);
      end
      else
      begin
        XTL.EmuXGUnswizzleRect
          (
          pSrc + dwMipOffs, dwMipWidth, dwMipHeight, dwDepth, LockedRect.pBits,
          LockedRect.Pitch, iRect, iPoint, dwBPP
          );
      end;
    end;
  end
  else if (bCompressed) then
  begin
                              // NOTE: compressed size is (dwWidth/2)*(dwHeight/2)/2, so each level divides by 4

    Move(pSrc + dwCompressedOffset, LockedRect.pBits, dwCompressedSize shr (level * 2));

    dwCompressedOffset := dwCompressedOffset + (dwCompressedSize shr (level * 2));
  end
  else
  begin
    BYTE * pDest := (BYTE)LockedRect.pBits;

    if ((DWORD)LockedRect.Pitch = dwMipPitch and dwMipPitch = dwMipWidth * dwBPP) then
    begin
      memcpy(pDest, pSrc + dwMipOffs, dwMipWidth * dwMipHeight * dwBPP);
    end
    else
    begin
      for (DWORD v := 0; v < dwMipHeight; v++)
      begin
        memcpy(pDest, pSrc + dwMipOffs, dwMipWidth * dwBPP);

        pDest := pDest + LockedRect.Pitch;
        pSrc := pSrc + dwMipPitch;
      end;
    end;
  end;
end;

if (dwCommonType = X_D3DCOMMON_TYPE_SURFACE) then
  pResource.EmuSurface8.UnlockRect()
else
begin
  if (bCubemap) then
    pResource.EmuCubeTexture8.UnlockRect((D3DCUBEMAP_FACES)r, 0)
  else
    pResource.EmuTexture8.UnlockRect(level);
end;

dwMipOffs := dwMipOffs + dwMipWidth * dwMipHeight * dwBPP;

dwMipWidth := dwMipWidth div 2;
dwMipHeight := dwMipHeight div 2;
dwMipPitch := dwMipPitch div 2;
end;
end;

              // Debug Texture Dumping
# ifdef _DEBUG_DUMP_TEXTURE_REGISTER
if (dwCommonType = X_D3DCOMMON_TYPE_SURFACE) then
begin
Integer dwDumpSurface := 0;

szBuffer: array[0..255 - 1] of Char;

StrFmt(szBuffer, _DEBUG_DUMP_TEXTURE_REGISTER '%.03 d - RegSurface%.03 d.bmp', X_Format, dwDumpSurface++);

D3DXSaveSurfaceToFile(szBuffer, D3DXIFF_BMP, pResource.EmuSurface8, 0, 0);
end
else
begin
if (bCubemap) then
begin
  Integer dwDumpCube := 0;

  szBuffer: array[0..255 - 1] of Char;

  for (Integer v := 0; v < 6; v++)
  begin
    IDirect3DSurface8 * pSurface := 0;

    StrFmt(szBuffer, _DEBUG_DUMP_TEXTURE_REGISTER '%.03 d - RegCubeTex%.03 d -%d.bmp', X_Format, dwDumpCube++, v);

    pResource.EmuCubeTexture8.GetCubeMapSurface((D3DCUBEMAP_FACES)v, 0, @pSurface);

    D3DXSaveSurfaceToFile(szBuffer, D3DXIFF_BMP, pSurface, 0, 0);
  end;
end
else
begin
  Integer dwDumpTex := 0;

  szBuffer: array[0..255 - 1] of Char;

  StrFmt(szBuffer, _DEBUG_DUMP_TEXTURE_REGISTER '%.03 d - RegTexture%.03 d.bmp', X_Format, dwDumpTex++);

  D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pResource.EmuTexture8, 0);
end;
end;
              //endif
end;

    end;  *)


    X_D3DCOMMON_TYPE_PALETTE:
    begin
      DbgPrintf('EmuIDirect3DResource8_Register: .Palette...');

      (*X_D3DPalette * pPalette := (X_D3DPalette)pResource;

      // create palette
      begin
        DWORD dwSize := EmuCheckAllocationSize(pBase, True);

        if (dwSize = -1) then
        begin
          // Cxbx TODO: once this is known to be working, remove the warning
          EmuWarning('Palette allocation size unknown');

          pPalette.Lock := X_D3DRESOURCE_LOCK_FLAG_NOSIZE;
        end;

        pCurrentPalette := pBase;

        pResource.Data := (ULONG)pBase;
      end;

      DbgPrintf('EmuIDirect3DResource8_Register : Successfully Created Palette (0x%.08X, 0x%.08X, 0x%.08X)', [pResource.Data, pResource.Size, pResource.AllocationSize]); *)
    end;


    X_D3DCOMMON_TYPE_FIXUP:
    begin
      pFixup := PX_D3DFixup(pResource);

      CxbxKrnlCleanup('IDirect3DReosurce8.Register.X_D3DCOMMON_TYPE_FIXUP is not yet supported' +
                #13#10'0x%.08 X(pFixup.Common)' +
                #13#10'0x%.08 X(pFixup.Data)' +
                #13#10'0x%.08 X(pFixup.Lock)' +
                #13#10'0x%.08 X(pFixup.Run)' +
                #13#10'0x%.08 X(pFixup.Next)' +
                #13#10'0x%.08 X(pFixup.Size)',
                [pFixup.Common, pFixup.Data, pFixup.Lock, pFixup.Run, pFixup.Next, pFixup.Size]);
    end;

  else // case
    CxbxKrnlCleanup('IDirect3DResource8.Register.Common cType 0x%.08 X not yet supported', [dwCommonType]);
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DResource8_AddRef(
  pThis: PX_D3DResource): ULONG; stdcall;
// Branch:martin  Revision:39 Done:55 Translator:Shadow_Tj
var
  uRet: ULONG;
  pResource8 : IDirect3DResource8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DResource8_AddRef' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10');',
    [pThis]);

  uRet := 0;

  pResource8 := pThis.EmuResource8;

    (*if(pThis.Lock = $8000BEEF) then
        uRet := ++pThis.Lock
    else if(pResource8 <> nil) then
        uRet := pResource8.AddRef(); *)

  EmuSwapFS(fsXbox);

  Result := uRet;
end;

function XTL_EmuIDirect3DResource8_Release(
  pThis: PX_D3DResource): ULONG; stdcall;
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
var
  uRet: ULONG;
  dwPtr : DWORD;
  pRefCount : ^DWORD;
  pResource8 : ^IDirect3DResource8;
  v : integer;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DResource8_Release' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10');',
    [pThis]);

  uRet := 0;
  (*if (IsSpecialResource(pThis.Data) and (pThis.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF)) then
  begin
    dwPtr := DWORD(pThis.Lock);
    pRefCount := DWORD(dwPtr + g_dwOverlayP*g_dwOverlayH);

    if(--(pRefCount) = 0) then
    begin
        // free memory associated with this special resource handle
        CxbxFree(PVOID(dwPtr));
     end;

    EmuSwapFS(fsXbox);
    EmuIDirect3DDevice8_EnableOverlay(False);
    EmuSwapFS(fsWindows);
  end
  else
  begin
    pResource8 := pThis.EmuResource8;

    if(pThis.Lock = $8000BEEF) then
    begin
        delete[] (PVOID)pThis.Data;
        uRet := --pThis.Lock;
     end
    else if(pResource8 <> 0) then
    begin
        for v := 0 to 15 - 1 do begin
            if(pCache[v].Data = pThis.Data) and (pThis.Data <> 0) then
            begin
                pCache[v].Data := 0;
                Break;
             end;
         end;

        {$ifdef _DEBUG_TRACE_VB}
        D3DRESOURCETYPE cType := pResource8.GetType();
        {$endif}

        uRet := pResource8.Release();

        if(uRet = 0) then
        begin
            DbgPrintf('EmuIDirect3DResource8_Release: Cleaned up a Resource!');

            {$ifdef _DEBUG_TRACE_VB}
            if(cType = D3DRTYPE_VERTEXBUFFER) then
            begin
                g_VBTrackTotal.remove(pResource8);
                g_VBTrackDisable.remove(pResource8);
             end;
            {$endif}

            //delete pThis;
         end;
     end;
  end;    *)


  EmuSwapFS(fsXbox);

  Result := uRet;
end;

function XTL_EmuIDirect3DResource8_IsBusy(pThis: PX_D3DResource): LONGBOOL;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pResource8: IDirect3DResource8;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DResource8_IsBusy' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10');',
    [pThis]);
  pResource8 := pThis.EmuResource8;
  EmuSwapFS(fsXbox);

  Result := False;
end;

function XTL_EmuIDirect3DResource8_GetType(
  pThis: PX_D3DResource): X_D3DRESOURCETYPE; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  rType: D3DRESOURCETYPE;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DResource8_GetType' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10');',
    [pThis]);

  // Cxbx TODO: Handle situation where the resource type is >7
  rType := pThis.EmuResource8.GetType();

  EmuSwapFS(fsXbox);

  Result := X_D3DRESOURCETYPE(rType);
end;

{ TODO: Need to be translated to delphi }

procedure XTL_EmuLock2DSurface(pPixelContainer : pX_D3DPixelContainer;
    FaceType : D3DCUBEMAP_FACES;
    Level : UINT;
    pLockedRect : _D3DLOCKED_RECT;
    pRect : PRect;
    Flags : DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet : HRESULT;
begin

  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuLock2DSurface' +
      #13#10'(' +
      #13#10'   pPixelContainer    : 0x%.08X' +
      #13#10'   FaceType           : 0x%.08X' +
      #13#10'   Level              : 0x%.08X' +
      #13#10'   pLockedRect        : 0x%.08X' +
      #13#10'   pRect              : 0x%.08X' +
      #13#10'   Flags              : 0x%.08X' +
      #13#10');',
      [pPixelContainer, @FaceType, Level, @pLockedRect, @pRect, Flags]);

  EmuVerifyResourceIsRegistered(pPixelContainer);

  hRet := pPixelContainer.EmuCubeTexture8.LockRect(FaceType, Level, pLockedRect, pRect, Flags);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuGet2DSurfaceDesc(pPixelContainer : pX_D3DPixelContainer;
    dwLevel : DWORD;
    pDesc : pX_D3DSURFACE_DESC);
// Branch:martin  Revision:39 Done:70 Translator:Shadow_Tj
var
  SurfaceDesc : D3DSURFACE_DESC;
  hRet : HRESULT;
begin
    EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuGet2DSurfaceDesc' +
           #13#10'(' +
           #13#10'   pPixelContainer    : 0x%.08X' +
           #13#10'   dwLevel            : 0x%.08X' +
           #13#10'   pDesc              : 0x%.08X' +
           #13#10');',
           [pPixelContainer, dwLevel, pDesc]);

    EmuVerifyResourceIsRegistered(pPixelContainer);

    ZeroMemory(@SurfaceDesc, SizeOf(SurfaceDesc));

    if(dwLevel = $FEFEFEFE) then
    begin
        hRet := pPixelContainer.EmuSurface8.GetDesc(SurfaceDesc);
        { marked by cxbx
         Integer dwDumpSurface := 0;
         szBuffer: array [0..255-1] of Char;
         StrFmt(szBuffer, 'C:\Aaron\Textures\Surface%.03d.bmp', dwDumpSurface++);
         D3DXSaveSurfaceToFile(szBuffer, D3DXIFF_BMP, pPixelContainer.EmuSurface8, 0, 0);
        }
    end
    else
    begin
        hRet := pPixelContainer.EmuTexture8.GetLevelDesc(dwLevel, SurfaceDesc);
        { marked out by cxbx
         Integer dwDumpTexture := 0;
         szBuffer: array [0..255-1] of Char;
         StrFmt(szBuffer, 'C:\Aaron\Textures\GetDescTexture%.03d.bmp', dwDumpTexture++);
         D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pPixelContainer.EmuTexture8, 0);
        }
    end;

    // rearrange into xbox format (remove D3DPOOL)
    begin
        // Convert Format (PC->Xbox)
        pDesc.Format := EmuPC2XB_D3DFormat(SurfaceDesc.Format);
        pDesc._Type   := X_D3DRESOURCETYPE(SurfaceDesc._Type);

        (*if(pDesc._Type > 7) then
            CxbxKrnlCleanup('EmuGet2DSurfaceDesc: pDesc._Type > 7'); *)

        pDesc.Usage  := SurfaceDesc.Usage;
        pDesc.Size   := SurfaceDesc.Size;

        // Cxbx TODO: Convert from Xbox to PC!!
        if(SurfaceDesc.MultiSampleType = D3DMULTISAMPLE_NONE) then
            pDesc.MultiSampleType := D3DMULTISAMPLE_TYPE($0011)
        else
            CxbxKrnlCleanup(Format('EmuGet2DSurfaceDesc Unknown Multisample format not  (%d)', [DWord(SurfaceDesc.MultiSampleType)]));

        pDesc.Width  := SurfaceDesc.Width;
        pDesc.Height := SurfaceDesc.Height; 
     end;

    EmuSwapFS(fsXbox);
end;

procedure XTL_EmuGet2DSurfaceDescD ( pPixelContainer : pX_D3DPixelContainer;
                                     pDesc : pX_D3DSURFACE_DESC );
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
    // debug trace
    {$IFDEF _DEBUG_TRACE}
    begin
        EmuSwapFS(fsWindows);
        DbgPrintf('EmuD3D8: EmuGet2DSurfaceDescD' +
               #13#10'(' +
               #13#10'   pPixelContainer    : 0x%.08X' +
               #13#10'   pDesc              : 0x%.08X' +
               #13#10');',
               [pPixelContainer, pDesc]);
        EmuSwapFS(fsXbox);
     end;
    {$endif}

    Xtl_EmuGet2DSurfaceDesc(pPixelContainer, $FEFEFEFE, pDesc);
end;

function XTL_EmuIDirect3DSurface8_GetDesc(pThis: PX_D3DResource;
  pDesc: PX_D3DSURFACE_DESC): HRESULT;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pSurface8 : ^IDirect3DSurface8;
  SurfaceDesc : D3DSURFACE_DESC;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DSurface8_GetDesc' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10'   pDesc              : 0x%.08X' +
    #13#10');',
    [pThis, pDesc]);

  EmuVerifyResourceIsRegistered(pThis);

  if IsSpecialResource(pThis.Data) and ((pThis.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF) > 0) then
  begin
    pDesc.Format := EmuPC2XB_D3DFormat(D3DFMT_YUY2);
    pDesc.Height := g_dwOverlayH;
    pDesc.Width := g_dwOverlayW;
    pDesc.MultiSampleType := D3DMULTISAMPLE_TYPE(0);
    pDesc.Size := g_dwOverlayP * g_dwOverlayH;
    pDesc._Type := X_D3DRTYPE_SURFACE;
    pDesc.Usage := 0;

    hRet := D3D_OK;
  end
  else
  begin
    (*pSurface8 := pThis.EmuSurface8;
    hRet := pSurface8.GetDesc(@SurfaceDesc);

    // rearrange into windows format (remove D3DPool)
    begin
      // Convert Format (PC->Xbox)
      pDesc.Format := EmuPC2XB_D3DSurfaceDesc.Format);
      pDesc.cType   := (X_D3DRESOURCETYPE)SurfaceDesc.cType;

      if(pDesc.cType > 7) then
          CxbxKrnlCleanup('EmuIDirect3DSurface8_GetDesc: pDesc.cType > 7');

      pDesc.Usage  := SurfaceDesc.Usage;
      pDesc.Size   := SurfaceDesc.Size;

      // Cxbx TODO: Convert from Xbox to PC!!
      if(SurfaceDesc.MultiSampleType = D3DMULTISAMPLE_NONE) then
          pDesc.MultiSampleType := (XTL.D3DMULTISAMPLE_TYPE)$0011;
      else
          CxbxKrnlCleanup('EmuIDirect3DSurface8_GetDesc Unknown Multisample format not  (%d)', SurfaceDesc.MultiSampleType);

      pDesc.Width  := SurfaceDesc.Width;
      pDesc.Height := SurfaceDesc.Height;
    end; *)
  end;

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DSurface8_LockRect(pThis: PX_D3DResource;
  pLockedRect: PD3DLOCKED_RECT;
  pRect: PRect;
  Flags: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);
  hret := 0;

  DbgPrintf('EmuD3D8: EmuIDirect3DSurface8_LockRect' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10'   pLockedRect        : 0x%.08X' +
    #13#10'   pRect              : 0x%.08X' +
    #13#10'   Flags              : 0x%.08X' +
    #13#10');',
    [pThis, pLockedRect, pRect, Flags]);

  EmuVerifyResourceIsRegistered(pThis);

  (*
  if(IsSpecialResource(pThis.Data) and (pThis.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF)) then
  begin
    pLockedRect.Pitch := g_dwOverlayP;
    pLockedRect.pBits := pThis.Lock;

    hRet := D3D_OK;
  end
  else
  begin
    if(Flags and $40) then
      EmuWarning('D3DLOCK_TILED ignored!');

    IDirect3DSurface8 *pSurface8 := pThis.EmuSurface8;

    DWORD NewFlags := 0;

    if(Flags and $80) then
      NewFlags:= NewFlags or D3DLOCK_READONLY;

    if(Flags and  not ($80 or $40)) then
      CxbxKrnlCleanup('EmuIDirect3DSurface8_LockRect: Unknown Flags not  (0x%.08X)', Flags);

    // Remove old lock(s)
    pSurface8.UnlockRect();

    hRet := pSurface8.LockRect(pLockedRect, pRect, NewFlags);

    if(FAILED(hRet)) then
      EmuWarning('LockRect Failed!');
  end;
  *)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DBaseTexture8_GetLevelCount(pThis: PX_D3DBaseTexture): DWORD;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  dwRet: DWORD;
  pBaseTexture8: IDirect3DBaseTexture8;
begin
  EmuSwapFS(fsWindows);
  dwRet := 0;

  DbgPrintf('EmuD3D8: EmuIDirect3DBaseTexture8_GetLevelCount' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10');',
    [@pThis]);

  EmuVerifyResourceIsRegistered(pThis);

  pBaseTexture8 := pThis.EmuBaseTexture8;

  dwRet := pBaseTexture8.GetLevelCount();
  EmuSwapFS(fsXbox);

  Result := dwRet;
end;

(*XTL.X_D3DResource * WINAPI XTL.EmuIDirect3DTexture8_GetSurfaceLevel2
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj
(
    X_D3DTexture   *pThis,
    UINT            Level
)
begin
    X_D3DSurface *pSurfaceLevel;

    // In a special situation, we are actually returning a memory ptr with high bit set
    if(IsSpecialResource(pThis.Data) and (pThis.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF)) then
    begin
        DWORD dwSize := g_dwOverlayP*g_dwOverlayH;

        DWORD *pRefCount := (DWORD)((DWORD)pThis.Lock + dwSize);

        // initialize ref count
        (pRefCount):= (pRefCount) + 1;

        Result := pThis;
     end;

    EmuIDirect3DTexture8_GetSurfaceLevel(pThis, Level, @pSurfaceLevel);

    Result := pSurfaceLevel;
end;
*)

function XTL_EmuIDirect3DTexture8_LockRect(pThis: PX_D3DTexture;
    Level: UINT;
    pLockedRect : pD3DLOCKED_RECT;
    CONST pRect : PRect;
    Flags : DWORD ): HRESULT;
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pTexture8 : ^IDirect3DTexture8;
  NewFlags : DWORD;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DTexture8_LockRect' +
           #13#10'(' +
           #13#10'   pThis              : 0x%.08X' +
           #13#10'   Level              : 0x%.08X' +
           #13#10'   pLockedRect        : 0x%.08X' +
           #13#10'   pRect              : 0x%.08X' +
           #13#10'   Flags              : 0x%.08X' +
           #13#10');',
           [pThis, Level, pLockedRect, pRect, Flags]);

    EmuVerifyResourceIsRegistered(pThis);

    // check if we have an unregistered YUV2 resource
    (*if( (pThis <> Nil) and IsSpecialResource(pThis.Data) and (pThis.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF)) then
    begin
        pLockedRect.Pitch := g_dwOverlayP;
        pLockedRect.pBits := PVOID(pThis.Lock);

        hRet := D3D_OK;
     end
    else
    begin
        pTexture8 := pThis.EmuTexture8;

        NewFlags := 0;

        if(Flags and $80) then
            NewFlags:= NewFlags or D3DLOCK_READONLY;

        if(Flags and  not ($80 or $40)) then
            CxbxKrnlCleanup('EmuIDirect3DTexture8_LockRect: Unknown Flags not  (0x%.08X)', Flags);


        // Remove old lock(s)
        pTexture8.UnlockRect(Level);

        hRet := pTexture8.LockRect(Level, pLockedRect, pRect, NewFlags);

        pThis.Common:= pThis.Common or X_D3DCOMMON_ISLOCKED;
     end;   *)

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DTexture8_GetSurfaceLevel( pThis: PX_D3DTexture;
    Level: UINT;
    ppSurfaceLevel: PX_D3DSurface ): HRESULT;
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DTexture8_GetSurfaceLevel' +
           #13#10'(' +
           #13#10'   pThis              : 0x%.08X' +
           #13#10'   Level              : 0x%.08X' +
           #13#10'   ppSurfaceLevel     : 0x%.08X' +
           #13#10');',
           [pThis, Level, ppSurfaceLevel]);

    EmuVerifyResourceIsRegistered(pThis);

    // if highest bit is set, this is actually a raw memory pointer (for YUY2 simulation)
    (*if(IsSpecialResource(pThis.Data) and (pThis.Data and X_D3DRESOURCE_DATA_FLAG_YUVSURF)) then
    begin
        DWORD dwSize := g_dwOverlayP*g_dwOverlayH;

        DWORD *pRefCount := (DWORD)((DWORD)pThis.Lock + dwSize);

        // initialize ref count
        (pRefCount):= (pRefCount) + 1;

        *ppSurfaceLevel := (X_D3DSurface)pThis;

        hRet := D3D_OK;
     end;
    else
    begin
        IDirect3DTexture8 *pTexture8 := pThis.EmuTexture8;

        *ppSurfaceLevel := new X_D3DSurface();

        (ppSurfaceLevel).Data := $B00BBABE;
        (ppSurfaceLevel).Common := 0;
        (ppSurfaceLevel).Format := 0;
        (ppSurfaceLevel).Size := 0;

        hRet := pTexture8.GetSurfaceLevel(Level,  and ((ppSurfaceLevel).EmuSurface8));

        if(FAILED(hRet)) then
        begin
            EmuWarning('EmuIDirect3DTexture8_GetSurfaceLevel Failed!');
         end;
        else
        begin
            DbgPrintf('EmuD3D8: EmuIDirect3DTexture8_GetSurfaceLevel := 0x%.08X', (ppSurfaceLevel).EmuSurface8);
         end;
     end;
     *)

  EmuSwapFS(fsXbox);
                        
  Result := hRet;
end;

function XTL_EmuIDirect3DVolumeTexture8_LockBox(pThis: PX_D3DVolumeTexture; Level: UINT;
  pLockedVolume: PD3DLOCKED_BOX; pBox: PD3DBOX; Flags: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pVolumeTexture8: IDirect3DVolumeTexture8;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DVolumeTexture8_LockBox' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10'   Level              : 0x%.08X' +
    #13#10'   pLockedVolume      : 0x%.08X' +
    #13#10'   pBox               : 0x%.08X' +
    #13#10'   Flags              : 0x%.08X' +
    #13#10');',
    [pThis, Level, pLockedVolume, pBox, Flags]);

  EmuVerifyResourceIsRegistered(pThis);
  pVolumeTexture8 := pThis.EmuVolumeTexture8;
  hRet := pVolumeTexture8.LockBox(Level, pLockedVolume^, pBox, Flags);

  if (FAILED(hRet)) then
    EmuWarning('LockBox Failed!');

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DCubeTexture8_LockRect(pThis: PX_D3DCubeTexture; FaceType: D3DCUBEMAP_FACES;
  Level: UINT; pLockedBox: PD3DLOCKED_RECT; pRect: PRect; Flags: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pCubeTexture8: IDirect3DCubeTexture8;
begin
  hret := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DCubeTexture8_LockRect' +
    #13#10'(' +
    #13#10'   pThis              : 0x%.08X' +
    #13#10'   FaceType           : 0x%.08X' +
    #13#10'   Level              : 0x%.08X' +
    #13#10'   pLockedBox         : 0x%.08X' +
    #13#10'   pRect              : 0x%.08X' +
    #13#10'   Flags              : 0x%.08X' +
    #13#10');',
    [pThis, Ord(FaceType), Level, pLockedBox, pRect, Flags]);

  EmuVerifyResourceIsRegistered(pThis);
  pCubeTexture8 := pThis.EmuCubeTexture8;
  hRet := pCubeTexture8.LockRect(FaceType, Level, pLockedBox^, pRect, Flags);

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_Release: ULONG;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  RefCount: DWORD;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_Release();');

  g_pD3DDevice8._AddRef();
  RefCount := g_pD3DDevice8._Release();
  if (RefCount = 1) then
  begin
    // Signal proxy thread, and wait for completion
    g_EmuCDPD.bReady := True;
    g_EmuCDPD.bCreate := False;

    while g_EmuCDPD.bReady do
      Sleep(10); // Dxbx : Should we use SwitchToThread() or YieldProcessor() ?

    RefCount := g_EmuCDPD.hRet;
  end
  else
  begin
    RefCount := g_pD3DDevice8._Release();
    // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
    if RefCount = 0 then
      Pointer(g_pD3DDevice8) := nil;
  end;

  EmuSwapFS(fsXbox);

  Result := RefCount;
end;

Function EmuIDirect3DDevice8_CreateVertexBuffer2(Length : UINT ) : PX_D3DVertexBuffer; stdcall;
// Branch:martin  Revision:39 Done:80 Translator:Shadow_Tj
var
  pD3DVertexBuffer : PX_D3DVertexBuffer;
begin
    EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreateVertexBuffer2' +
           #13#10'(' +
           #13#10'   Length             : 0x%.08X' +
           #13#10');',
           [Length]);

    (*X_D3DVertexBuffer *pD3DVertexBuffer := new X_D3DVertexBuffer();

    HRESULT hRet = g_pD3DDevice8.CreateVertexBuffer
    (
        Length,
        0,
        0,
        D3DPOOL_MANAGED,
        @pD3DVertexBuffer.EmuVertexBuffer8
    );

    if(FAILED(hRet)) then
        EmuWarning('CreateVertexBuffer Failed!');    *)

    {$ifdef _DEBUG_TRACK_VB}
    g_VBTrackTotal.insert(pD3DVertexBuffer.EmuVertexBuffer8);
    {$endif}

    EmuSwapFS(fsXbox);

    Result := pD3DVertexBuffer;
end;

function XTL_EmuIDirect3DDevice8_CreateVertexBuffer(Length: UINT;
  Usage: DWORD; FVF: DWORD; Pool: D3DPOOL;
  ppVertexBuffer: PX_D3DVertexBuffer): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  ppVertexBuffer := EmuIDirect3DDevice8_CreateVertexBuffer2(Length);
  Result := D3D_OK;
end;      

procedure XTL_EmuIDirect3DDevice8_EnableOverlay(Enable: Boolean); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  ddsd2: DDSURFACEDESC2;
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_EnableOverlay' +
    #13#10'(' +
    #13#10'   Enable             : 0x%.08X' +
    #13#10');',
    [Enable]);

  if (not Enable) and Assigned(g_pDDSOverlay7) then
  begin
    g_pDDSOverlay7.UpdateOverlay(nil, g_pDDSPrimary, nil, DDOVER_HIDE, nil);

    // cleanup overlay clipper
    if Assigned(g_pDDClipper) then
    begin
      g_pDDClipper._Release();
      // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
      Pointer(g_pDDClipper) := nil;
    end;

    // cleanup overlay surface
    if Assigned(g_pDDSOverlay7) then
    begin
      g_pDDSOverlay7._Release();
      // Dxbx note : Watch out for compiler-magic, and clear interface as a pointer :
      Pointer(g_pDDSOverlay7) := nil;
    end;
  end
  else
    if (Enable and (g_pDDSOverlay7 = nil)) then
    begin
        // initialize overlay surface
      if (g_bSupportsYUY2) then
      begin
        ZeroMemory(@ddsd2, SizeOf(ddsd2));

        ddsd2.dwSize := SizeOf(ddsd2);
        ddsd2.dwFlags := DDSD_CAPS or DDSD_WIDTH or DDSD_HEIGHT or DDSD_PIXELFORMAT;
        ddsd2.ddsCaps.dwCaps := DDSCAPS_OVERLAY;
        ddsd2.dwWidth := g_dwOverlayW;
        ddsd2.dwHeight := g_dwOverlayH;

        ddsd2.ddpfPixelFormat.dwSize := SizeOf(DDPIXELFORMAT);
        ddsd2.ddpfPixelFormat.dwFlags := DDPF_FOURCC;
        ddsd2.ddpfPixelFormat.dwFourCC := MAKEFOURCC('Y', 'U', 'Y', '2');

        hRet := g_pDD7.CreateSurface(ddsd2, {out} g_pDDSOverlay7, nil);

        if (FAILED(hRet)) then
          CxbxKrnlCleanup('Could not create overlay surface');

        hRet := g_pDD7.CreateClipper(0, g_pDDClipper, nil);

        if (FAILED(hRet)) then
          CxbxKrnlCleanup('Could not create overlay clipper');

        hRet := g_pDDClipper.SetHWnd(0, g_hEmuWindow);
      end;
    end;

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_UpdateOverlay(pSurface: PX_D3DSurface;
  SrcRect: PRect;
  DstRect: PRect;
  EnableColorKey: BOOL;
  ColorKey: D3DCOLOR); stdcall;
// Branch:martin  Revision:39 Done:20 Translator:Shadow_Tj
var
  ddsd2: DDSURFACEDESC2;
  pDest: Pointer;
  pSour: DWord;
  w: Integer;
  h: Integer;
  SourRect: TRect;
  y: Integer;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_UpdateOverlay' +
    #13#10'(' +
    #13#10'   pSurface           : 0x%.08X' +
    #13#10'   SrcRect            : 0x%.08X' +
    #13#10'   DstRect            : 0x%.08X' +
    #13#10'   EnableColorKey     : 0x%.08X' +
    #13#10'   ColorKey           : 0x%.08X' +
    #13#10');',
    [pSurface, SrcRect, DstRect, EnableColorKey, ColorKey]);

  // manually copy data over to overlay
  if (g_bSupportsYUY2) then
  begin
    ZeroMemory(@ddsd2, SizeOf(ddsd2));

    ddsd2.dwSize := SizeOf(ddsd2);

    g_pDDSOverlay7.Lock(nil, ddsd2, DDLOCK_SURFACEMEMORYPTR or DDLOCK_WAIT, 0);

        // copy data
    begin
      pDest := ddsd2.lpSurface;
      pSour := pSurface.Lock;

      w := g_dwOverlayW;
      h := g_dwOverlayH;

      // Cxbx TODO: sucker the game into rendering directly to the overlay (speed boost)
      if ((ddsd2.lPitch = w * 2) and (g_dwOverlayP = w * 2)) then
        Move(pSour, pDest, h * w * 2)
      else
      begin
        for y := 0 to h - 1 do begin
          Move(pSour, pDest, w * 2);

          (*pDest:= pDest + ddsd2.lPitch;
          pSour:= pSour + g_dwOverlayP; *)
        end;
      end;
    end;

    g_pDDSOverlay7.Unlock(nil);
  end;

  // update overlay!
  if (g_bSupportsYUY2) then
  begin
        (*SourRect := (0, 0, g_dwOverlayW, g_dwOverlayH), DestRect;
        MONITORINFO MonitorInfo := (0);

        Integer nTitleHeight  := 0;//GetSystemMetrics(SM_CYCAPTION);
        Integer nBorderWidth  := 0;//GetSystemMetrics(SM_CXSIZEFRAME);
        Integer nBorderHeight := 0;//GetSystemMetrics(SM_CYSIZEFRAME);

        MonitorInfo.cbSize := SizeOf(MONITORINFO);
        GetMonitorInfo(g_hMonitor, @MonitorInfo);

        GetWindowRect(g_hEmuWindow, @DestRect);

        DestRect.left  :=  + nBorderWidth;
        DestRect.right := DestRect.right - nBorderWidth;
        DestRect.top   :=  + nTitleHeight + nBorderHeight;
        DestRect.bottom:= DestRect.bottom - nBorderHeight;

        DestRect.left  :=  - MonitorInfo.rcMonitor.left;
        DestRect.right := DestRect.right - MonitorInfo.rcMonitor.left;
        DestRect.top   :=  - MonitorInfo.rcMonitor.top;
        DestRect.bottom:= DestRect.bottom - MonitorInfo.rcMonitor.top;

        DDOVERLAYFX ddofx;

        ZeroMemory(@ddofx, SizeOf(ddofx));

        ddofx.dwSize := SizeOf(DDOVERLAYFX);
        ddofx.dckDestColorkey.dwColorSpaceLowValue := 0;
        ddofx.dckDestColorkey.dwColorSpaceHighValue := 0;

        HRESULT hRet := g_pDDSOverlay7.UpdateOverlay(@SourRect, g_pDDSPrimary, @DestRect, (*DDOVER_KEYDESTOVERRIDE | *)(*DDOVER_SHOW, /*&ddofx*/0); *)
  end
  else
  begin
        // Cxbx TODO: dont assume X8R8G8B8 ?
        (*D3DLOCKED_RECT LockedRectDest;

        IDirect3DSurface8 *pBackBuffer:=0;

        HRESULT hRet := g_pD3DDevice8.GetBackBuffer(0, D3DBACKBUFFER_TYPE_MONO, @pBackBuffer);

        // if we obtained the backbuffer, manually translate the YUY2 into the backbuffer format
        if(hRet = D3D_OK and pBackBuffer.LockRect(@LockedRectDest, 0, 0) = D3D_OK) then
        begin
            uint08 *pCurByte := (uint08)pSurface.Lock;

            uint08 *pDest := (uint08)LockedRectDest.pBits;

            uint32 dx:=0, dy=0;

            uint32 dwImageSize := g_dwOverlayP*g_dwOverlayH;

            // grayscale
            if(False) then
            begin
                for(uint32 y:=0;y<g_dwOverlayH;y++)
                begin
                    uint32 stop := g_dwOverlayW*4;
                    for(uint32 x:=0;x<stop;x+=4)
                    begin
                        uint08 Y := *pCurByte;

                        pDest[x+0] := Y;
                        pDest[x+1] := Y;
                        pDest[x+2] := Y;
                        pDest[x+3] := $FF;

                        pCurByte+:=2;
                     end;

                    pDest:= pDest + LockedRectDest.Pitch;
                 end;
             end;
            // full color conversion (YUY2->XRGB)
            else
            begin
                for(uint32 v:=0;v<dwImageSize;v+=4)
                begin
                    Single Y[2], U, V;

                    Y[0] = *pCurByte:= *pCurByte + 1;
                    U    = *pCurByte:= *pCurByte + 1;
                    Y[1] = *pCurByte:= *pCurByte + 1;
                    V    = *pCurByte:= *pCurByte + 1;

                    Integer a:=0;
                    for(Integer x:=0;x<2;x++)
                    begin
                        Single R := Y[a] + 1.402f*(V-128);
                        Single G := Y[a] - 0.344f*(U-128) - 0.714f*(V-128);
                        Single B := Y[a] + 1.772f*(U-128);

                        R := (R < 0) ? 0: ((R > 255) ? 255: R);
                        G := (G < 0) ? 0: ((G > 255) ? 255: G);
                        B := (B < 0) ? 0: ((B > 255) ? 255: B);

                        uint32 i := (dy*LockedRectDest.Pitch+(dx+x)*4);

                        pDest[i+0] := (uint08)B;
                        pDest[i+1] := (uint08)G;
                        pDest[i+2] := (uint08)R;
                        pDest[i+3] := $FF;

                        a:= a + 1;
                     end;

                    dx+:=2;

                    if((dx%g_dwOverlayW) = 0) then
                    begin
                        dy:= dy + 1;
                        dx:=0;
                     end;

                 end;
             end;

            pBackBuffer.UnlockRect();
         end;
         *)
  end;

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_GetOverlayUpdateStatus(): LONGBOOL; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetOverlayUpdateStatus();');

  EmuSwapFS(fsXbox);

  // Cxbx TODO: Actually check for update status
  Result := False;
end;

procedure XTL_EmuIDirect3DDevice8_BlockUntilVerticalBlank; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BlockUntilVerticalBlank();');

    // Marked out by cxbx
    // segaGT tends to freeze with this on
    //    if(g_XBVideo.GetVSync())
  g_pDD7.WaitForVerticalBlank(DDWAITVB_BLOCKBEGIN, 0);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetVerticalBlankCallback(pCallback: D3DVBLANKCALLBACK);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVerticalBlankCallback' +
    #13#10'(' +
    #13#10'   pCallback          : 0x%.08X' +
    #13#10');',
    [@pCallback]);

  g_pVBCallback := pCallback;

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetTextureState_TexCoordIndex(Stage: DWord; Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTextureState_TexCoordIndex' +
    #13#10'(' +
    #13#10'   Stage              : 0x%.08X' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Stage, Value]);

  if (Value > $00030000) then
    CxbxKrnlCleanup('EmuIDirect3DDevice8_SetTextureState_TexCoordIndex: Unknown TexCoordIndex Value (0x%.08X)', [Value]);

  g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_TEXCOORDINDEX, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetTextureState_TwoSidedLighting(Value: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTextureState_TwoSidedLighting' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('TwoSidedLighting is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetTextureState_BackFillMode(Value: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTextureState_BackFillMode' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('BackFillMode is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetTextureState_BorderColor(Stage: DWord; Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTextureState_BorderColor' +
    #13#10'(' +
    #13#10'   Stage              : 0x%.08X' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Stage, Value]);

  g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_BORDERCOLOR, Value);
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetTextureState_ColorKeyColor(Stage: DWord; Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTextureState_ColorKeyColor' +
    #13#10'(' +
    #13#10'   Stage              : 0x%.08X' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Stage, Value]);

  EmuWarning('SetTextureState_ColorKeyColor is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetTextureState_BumpEnv(
    Stage: DWORD;
    cType: X_D3DTEXTURESTAGESTATETYPE;
    Value: DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
    EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTextureState_BumpEnv' +
           #13#10'(' +
           #13#10'   Stage              : 0x%.08X' +
           #13#10'   cType               : 0x%.08X' +
           #13#10'   Value              : 0x%.08X' +
           #13#10');',
           [Stage, cType, Value]);

    case(cType) of
         22:    // X_D3DTSS_BUMPENVMAT00
            g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_BUMPENVMAT00, Value);
         23:    // X_D3DTSS_BUMPENVMAT01
            g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_BUMPENVMAT01, Value);
         24:    // X_D3DTSS_BUMPENVMAT11
            g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_BUMPENVMAT11, Value);
         25:    // X_D3DTSS_BUMPENVMAT10
            g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_BUMPENVMAT10, Value);
         26:    // X_D3DTSS_BUMPENVLSCALE
            g_pD3DDevice8.SetTextureStageState(Stage, D3DTSS_BUMPENVLSCALE, Value);
     end;

    EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_FrontFace(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_FrontFace' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_FrontFace not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_LogicOp(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_LogicOp' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_LogicOp is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_NormalizeNormals(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_NormalizeNormals' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_NORMALIZENORMALS, Value);
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_TextureFactor(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_TextureFactor' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_TEXTUREFACTOR, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_ZBias(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_ZBias' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_ZBIAS, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_EdgeAntiAlias(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_EdgeAntiAlias' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_EDGEANTIALIAS, Value);

  EmuWarning('SetRenderState_EdgeAntiAlias not implemented!');
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_FillMode(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  dwFillMode: DWORD;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_FillMode' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  if (g_iWireframe = 0) then
    dwFillMode := EmuXB2PC_D3DFILLMODE(Value)
  else if (g_iWireframe = 1) then
    dwFillMode := D3DFILL_WIREFRAME
  else
    dwFillMode := D3DFILL_POINT;

  g_pD3DDevice8.SetRenderState(D3DRS_FILLMODE, dwFillMode);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_FogColor(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_FogColor' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_FOGCOLOR, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_Dxt1NoiseEnable(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_Dxt1NoiseEnable' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_Dxt1NoiseEnable not implemented!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_Simple
  (
  Method: DWORD;
  Value: DWORD
  ); register;
// Branch:martin  Revision:39 Done:80 Translator:Shadow_Tj
var
  State: Integer;
  v: integer;
  OrigValue: DWORD;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf(DxbxFormat('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_Simple' +
    #13#10'(' +
    #13#10'   Method             : 0x%.08X' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Method, Value]));

  State := -1;

  // Cxbx TODO: make this faster and more elegant
  for v := 0 to 173 do
  begin
    (*
    if (EmuD3DRenderStateSimpleEncoded[v] = Method) then
    begin
      State := v;
      Break;
    end;
    *)
  end;

  if (State = -1) then
    EmuWarning('RenderState_Simple(0x%.08X, 0x%.08X) is unsupported!', [Method, Value])
  else
  begin
    case (State) of
      168: //D3DRS_COLORWRITEENABLE:
        begin
          OrigValue := Value;

          Value := 0;

                (*if(OrigValue and (1L shl 16)) then
                    Value:= Value or D3DCOLORWRITEENABLE_RED;
                if(OrigValue and (1L shl 8)) then
                    Value:= Value or D3DCOLORWRITEENABLE_GREEN;
                if(OrigValue and (1L shl 0)) then
                    Value:= Value or D3DCOLORWRITEENABLE_BLUE;
                if(OrigValue and (1L shl 24)) then
                    Value:= Value or D3DCOLORWRITEENABLE_ALPHA; *)

          DbgPrintf('D3DRS_COLORWRITEENABLE := 0x%.08X', Value);
        end;

      9: //D3DRS_SHADEMODE:
        begin
          Value := Value and $03;
          DbgPrintf('D3DRS_SHADEMODE := 0x%.08X', Value);
        end;

      171: //D3DRS_BLENDOP:
        begin
          Value := EmuXB2PC_D3DBLENDOP(Value);
          DbgPrintf('D3DRS_BLENDOP := 0x%.08X', Value);
        end;

      19: //D3DRS_SRCBLEND:
        begin
          Value := EmuXB2PC_D3DBLEND(Value);
          DbgPrintf('D3DRS_SRCBLEND := 0x%.08X', Value);
        end;

      20: //D3DRS_DESTBLEND:
        begin
          Value := EmuXB2PC_D3DBLEND(Value);
          DbgPrintf('D3DRS_DESTBLEND := 0x%.08X', Value);
        end;

      23: //D3DRS_ZFUNC:
        begin
          Value := EmuXB2PC_D3DCMPFUNC(Value);
          DbgPrintf('D3DRS_ZFUNC := 0x%.08X', Value);
        end;

      25: //D3DRS_ALPHAFUNC:
        begin
          Value := EmuXB2PC_D3DCMPFUNC(Value);
          DbgPrintf('D3DRS_ALPHAFUNC := 0x%.08X', Value);
        end;

      15: //D3DRS_ALPHATESTENABLE:
        begin
          DbgPrintf('D3DRS_ALPHATESTENABLE := 0x%.08X', Value);
        end;

      27: //D3DRS_ALPHABLENDENABLE:
        begin
          DbgPrintf('D3DRS_ALPHABLENDENABLE := 0x%.08X', Value);
        end;

      24: //D3DRS_ALPHAREF:
        begin
          DbgPrintf('D3DRS_ALPHAREF := %lf', DWtoF(Value));
        end;

      14: //D3DRS_ZWRITEENABLE:
        begin
          DbgPrintf('D3DRS_ZWRITEENABLE := 0x%.08X', Value);
        end;

      26: //D3DRS_DITHERENABLE:
        begin
          DbgPrintf('D3DRS_DITHERENABLE := 0x%.08X', Value);
        end;
    else
      begin
        CxbxKrnlCleanup('Unsupported RenderState (0x%.08X)', [State]);
      end;
    end;

    // Cxbx TODO: verify these params as you add support for them!
    g_pD3DDevice8.SetRenderState(D3DRENDERSTATETYPE(State), Value);
  end;

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_VertexBlend(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_VertexBlend' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

    // convert from Xbox direct3d to PC direct3d enumeration
  if (Value <= 1) then
    Value := Value
  else if (Value = 3) then
    Value := 2
  else if (Value = 5) then
    Value := 3
  else
    CxbxKrnlCleanup('Unsupported D3DVERTEXBLENDFLAGS (%d)', [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_VERTEXBLEND, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_PSTextureModes(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_PSTextureModes' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

    // Cxbx TODO: do something..

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_CullMode(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_CullMode' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

    // convert from Xbox D3D to PC D3D enumeration
    // Cxbx TODO: XDK-Specific Tables? So far they are the same
  case (Value) of
    0:
      Value := D3DCULL_NONE;
    $900:
      Value := D3DCULL_CW;
    $901:
      Value := D3DCULL_CCW;
  else
    CxbxKrnlCleanup('EmuIDirect3DDevice8_SetRenderState_CullMode: Unknown Cullmode (%d)', [Value]);
  end;

  g_pD3DDevice8.SetRenderState(D3DRS_CULLMODE, Value);
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_LineWidth(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_LineWidth' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

    // Cxbx TODO: Convert to PC format??
  g_pD3DDevice8.SetRenderState(D3DRS_LINEPATTERN, Value);
  EmuWarning('SetRenderState_LineWidth is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_StencilFail(Value: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_StencilFail' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_STENCILFAIL, Value);
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_OcclusionCullEnable(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_OcclusionCullEnable' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_OcclusionCullEnable not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_StencilCullEnable(Value: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_StencilCullEnable' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_StencilCullEnable not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_RopZCmpAlwaysRead(Value: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_RopZCmpAlwaysRead' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_RopZCmpAlwaysRead not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_RopZRead(Value: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_RopZRead' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_RopZRead not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_DoNotCullUncompressed(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_DoNotCullUncompressed' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_DoNotCullUncompressed not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_ZEnable(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_ZEnable' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);
  g_pD3DDevice8.SetRenderState(D3DRS_ZENABLE, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_StencilEnable(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_StencilEnable' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_STENCILENABLE, Value);
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleAntiAlias(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_MultiSampleAntiAlias' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_MULTISAMPLEANTIALIAS, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleMask(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_MultiSampleMask' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  g_pD3DDevice8.SetRenderState(D3DRS_MULTISAMPLEMASK, Value);

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleMode(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_MultiSampleMode' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_MultiSampleMode is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleRenderTargetMode(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_MultiSampleRenderTargetMode' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('SetRenderState_MultiSampleRenderTargetMode is not supported!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_ShadowFunc(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_ShadowFunc' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('ShadowFunc not implemented');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetRenderState_YuvEnable(Value: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderState_YuvEnable' +
    #13#10'(' +
    #13#10'   Value              : 0x%.08X' +
    #13#10');',
    [Value]);

  EmuWarning('YuvEnable not implemented (0x%.08X)', [Value]);

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetTransform(State: D3DTRANSFORMSTATETYPE;
  pMatrix: D3DMATRIX): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetTransform' +
    #13#10'(' +
    #13#10'   State              : 0x%.08X' +
    #13#10'   pMatrix            : 0x%.08X' +
    #13#10');',
    [@State, @pMatrix]);

  { Commented by CXBX

  DbgPrintf('pMatrix (%d)', [State]);
  DbgPrintf('begin ');
  DbgPrintf('    %.08f,%.08f,%.08f,%.08f', [pMatrix._11, pMatrix._12, pMatrix._13, pMatrix._14]);
  DbgPrintf('    %.08f,%.08f,%.08f,%.08f', [pMatrix._21, pMatrix._22, pMatrix._23, pMatrix._24]);
  DbgPrintf('    %.08f,%.08f,%.08f,%.08f', [pMatrix._31, pMatrix._32, pMatrix._33, pMatrix._34]);
  DbgPrintf('    %.08f,%.08f,%.08f,%.08f', [pMatrix._41, pMatrix._42, pMatrix._43, pMatrix._44]);
  DbgPrintf(' end;');

  if (State = 6 and (pMatrix._11 = 1.0) and (pMatrix._22 = 1.0) and (pMatrix._33 = 1.0) and (pMatrix._44 = 1.0)) then
  begin
    Xtl_g_bSkipPush := TRUE;
    DbgPrintf('SkipPush ON');
  end
  else
  begin
    Xtl_g_bSkipPush := False;
    DbgPrintf('SkipPush OFF');
  end;
  }

  State := EmuXB2PC_D3DTS(State);

  hRet := g_pD3DDevice8.SetTransform(State, pMatrix);

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_GetTransform(State: D3DTRANSFORMSTATETYPE; pMatrix: D3DMATRIX): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetTransform' +
    #13#10'(' +
    #13#10'   State              : 0x%.08X' +
    #13#10'   pMatrix            : 0x%.08X' +
    #13#10');',
    [@State, @pMatrix]);

    State := EmuXB2PC_D3DTS(State);

    hRet := g_pD3DDevice8.GetTransform(State, pMatrix);

  EmuSwapFS(fsXbox);
  Result := hRet;
end;

procedure XTL_EmuIDirect3DVertexBuffer8_Lock(ppVertexBuffer: PX_D3DVertexBuffer;
  OffsetToLock: UINT; SizeToLock: UINT; ppbData: PPByte; Flags: DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pVertexBuffer8: IDirect3DVertexBuffer8;
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DVertexBuffer8_Lock' +
    #13#10'(' +
    #13#10'   ppVertexBuffer     : 0x%.08X' +
    #13#10'   OffsetToLock       : 0x%.08X' +
    #13#10'   SizeToLock         : 0x%.08X' +
    #13#10'   ppbData            : 0x%.08X' +
    #13#10'   Flags              : 0x%.08X' +
    #13#10');',
    [ppVertexBuffer, OffsetToLock, SizeToLock, ppbData, Flags]);

  pVertexBuffer8 := ppVertexBuffer.EmuVertexBuffer8;

  hRet := pVertexBuffer8.Lock(OffsetToLock, SizeToLock, ppbData^, Flags);

  if (FAILED(hRet)) then
    EmuWarning('VertexBuffer Lock Failed!');

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DVertexBuffer8_Lock2(ppVertexBuffer : PX_D3DVertexBuffer;
    Flags : DWORD ): PByte; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  pVertexBuffer8 : IDirect3DVertexBuffer8;
  pbData : PBYTE;
  hRet : HRESULT;
begin
    EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DVertexBuffer8_Lock2' +
           #13#10'(' +
           #13#10'   ppVertexBuffer     : 0x%.08X' +
           #13#10'   Flags              : 0x%.08X' +
           #13#10');',
           [ppVertexBuffer, Flags]);

    pVertexBuffer8 := ppVertexBuffer.EmuVertexBuffer8;

    pbData :=Nil;

    hRet := pVertexBuffer8.Lock(0, 0, pbData, EmuXB2PC_D3DLock(Flags));	// Fixed flags check, Battlestar Galactica now displays graphics correctly

    EmuSwapFS(fsXbox);

    Result := pbData;
end;

function XTL_EmuIDirect3DDevice8_GetStreamSource2( StreamNumber : UINT;
    pStride : PUINT) : PX_D3DVertexBuffer;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
var
  pVertexBuffer : PX_D3DVertexBuffer;
begin
    EmuSwapFS(fsWindows);

    // debug trace
    DbgPrintf( 'EmuD3D8 : EmuIDirect3DDevice8_GetStreamSource2'+
               #13#10'(' +
               #13#10'   StreamNumber              : 0x%.08X' +
               #13#10'   pStride                   : 0x%.08X' +
               #13#10');',
               [StreamNumber, pStride]);

    EmuWarning('Not correctly implemented yet!');
    (*g_pD3DDevice8.GetStreamSource(StreamNumber, IDirect3DVertexBuffer8 (@pVertexBuffer), pStride); *)
    EmuSwapFS(fsXbox);
    Result := pVertexBuffer;
end;

function XTL_EmuIDirect3DDevice8_SetStreamSource(StreamNumber: UINT;
  pStreamData: X_D3DVertexBuffer; Stride: UINT): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:3 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  hret := 0;

  EmuSwapFS(fsWindows);

  (*DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetStreamSource' +
    #13#10'(' +
    #13#10'   StreamNumber       : 0x%.08X' +
    #13#10'   pStreamData        : 0x%.08X (0x%.08X)' +
    #13#10'   Stride             : 0x%.08X' +
    #13#10');',
    [StreamNumber, pStreamData, ifThen(pStreamData <> nil, pStreamData.EmuVertexBuffer8: 0, Stride)]);
    *)
   (* if(StreamNumber = 0) then
        g_pVertexBuffer := pStreamData;

    IDirect3DVertexBuffer8 *pVertexBuffer8 := 0;

    if(pStreamData <> 0) then
    begin
        EmuVerifyResourceIsRegistered(pStreamData);

        pVertexBuffer8 := pStreamData.EmuVertexBuffer8;
        pVertexBuffer8.Unlock();
     end;

    #ifdef _DEBUG_TRACK_VB
    if(pStreamData <> 0) then
    begin
        g_bVBSkipStream := g_VBTrackDisable.exists(pStreamData.EmuVertexBuffer8);
     end;
    //endif

    HRESULT hRet := g_pD3DDevice8.SetStreamSource(StreamNumber, pVertexBuffer8, Stride);

    if(FAILED(hRet)) then
        CxbxKrnlCleanup('SetStreamSource Failed!');
*)
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_SetVertexShader(aHandle: DWord): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:40 Translator:Shadow_Tj
var
  hRet: HRESULT;
  RealHandle: DWORD;
  {vOffset: TD3DXVECTOR4;
  vScale: TD3DXVECTOR4; } // not neccesery because cxbx commented the use
begin
  RealHandle := 0;
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexShader' +
    #13#10'(' +
    #13#10'   Handle             : 0x%.08X' +
    #13#10');',
    [aHandle]);

  hRet := D3D_OK;

  g_CurrentVertexShader := aHandle;

    { What have you been trying to do here?  --- CXBX COMMENTS
    XTL.D3DXVECTOR4 vOffset;
    XTL.D3DXVECTOR4 vScale;

    EmuSwapFS(fsXbox);
    EmuIDirect3DDevice8_GetViewportOffsetAndScale(@vOffset, @vScale);
    EmuSwapFS(fsWindows);
    }

  if (g_VertexShaderConstantMode <> X_VSCM_NONERESERVED) then
  begin
        //g_pD3DDevice8.SetVertexShaderConstant( 58, &vScale, 1 );   -- MARKED OUT IN CXBX
        //g_pD3DDevice8.SetVertexShaderConstant( 59, &vOffset, 1 );  -- MARKED OUT IN CXBX
  end;

  if (VshHandleIsVertexShader(aHandle)) then
  begin
    (*RealHandle := VshHandleGetVertexShader(Handle)) - > Handle) - > Handle; *)
  end
  else
  begin
    RealHandle := aHandle;
  end;
  hRet := g_pD3DDevice8.SetVertexShader(RealHandle);

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

procedure XTL_EmuIDirect3DDevice8_DrawVertices(PrimitiveType: X_D3DPRIMITIVETYPE;
  StartVertex: UINT; VertexCount: UINT); stdcall;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  PrimitiveCount: UINT;
  PCPrimitiveType: D3DPRIMITIVETYPE;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_DrawVertices' +
    #13#10'(' +
    #13#10'   PrimitiveType      : 0x%.08X' +
    #13#10'   StartVertex        : 0x%.08X' +
    #13#10'   VertexCount        : 0x%.08X' +
    #13#10');',
    [@PrimitiveType, StartVertex, VertexCount]);

    XTL_EmuUpdateDeferredStates();

  if ((PrimitiveType = X_D3DPT_QUADSTRIP) or (PrimitiveType = X_D3DPT_POLYGON)) then
    EmuWarning(Format('Unsupported PrimitiveType! (%d)', [DWord(PrimitiveType)]));

(*    PrimitiveCount := EmuD3DVertex2PrimitiveCount(DWord(PrimitiveType), VertexCount);

    // Convert from Xbox to PC enumeration
    PCPrimitiveType := PrimitiveType;

    VertexPatchDesc VPDesc;

    VPDesc.dwVertexCount := VertexCount;
    VPDesc.PrimitiveType := PrimitiveType;
    VPDesc.dwPrimitiveCount := PrimitiveCount;
    VPDesc.dwOffset := StartVertex;
    VPDesc.pVertexStreamZeroData := 0;
    VPDesc.uiVertexStreamZeroStride := 0;
    VPDesc.hVertexShader := g_CurrentVertexShader;

    VertexPatcher VertPatch;

    bool bPatched := VertPatch.Apply(@VPDesc);

    if(IsValidCurrentShader()) then
    begin
        #ifdef _DEBUG_TRACK_VB
        if(g_bVBSkipStream) then
        begin
            g_pD3DDevice8.DrawPrimitive
            (
                PCPrimitiveType,
                StartVertex,
                0
            );
         end;
        else
        begin
        //endif
            g_pD3DDevice8.DrawPrimitive
            (
                PCPrimitiveType,
                StartVertex,
                VPDesc.dwPrimitiveCount
            );
        #ifdef _DEBUG_TRACK_VB
         end;
        //endif
     end;

    VertPatch.Restore();
    *)
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_DrawVerticesUP(PrimitiveType: X_D3DPRIMITIVETYPE;
  VertexCount: UINT; pVertexStreamZeroData: PVOID; VertexStreamZeroStride: UINT); stdcall;
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_DrawVerticesUP' +
    #13#10'(' +
    #13#10'   PrimitiveType           : 0x%.08X' +
    #13#10'   VertexCount             : 0x%.08X' +
    #13#10'   pVertexStreamZeroData   : 0x%.08X' +
    #13#10'   VertexStreamZeroStride  : 0x%.08X' +
    #13#10');',
    [@PrimitiveType, VertexCount, pVertexStreamZeroData,
    VertexStreamZeroStride]);

    Xtl_EmuUpdateDeferredStates();    

    if( (PrimitiveType = X_D3DPT_QUADSTRIP) or (PrimitiveType = X_D3DPT_POLYGON) ) then
      CxbxKrnlCleanup(Format('Unsupported PrimitiveType not  (%d)', [DWORD(PrimitiveType)]));

    (*
    // DEBUG
    begin
         FLOAT fixer[] =
        begin
            0.0f, 0.0f, 1.0f,
            0.0f, 480.0f, 1.0f,
            640.0f, 0.0f, 1.0f,
            640.0f, 480.0f, 1.0f,
        );

        DWORD *pdwVB := (DWORD)pVertexStreamZeroData;

        for(uint r:=0;r<VertexCount;r++)
        begin
            pdwVB[0] := FtoDW(fixer[r*3+0]);
            pdwVB[1] := FtoDW(fixer[r*3+1]);
            pdwVB[2] := FtoDW(fixer[r*3+2]);
            pdwVB[5] := $FFFFFFFF;

            FLOAT px := DWtoF(pdwVB[0]);
            FLOAT py := DWtoF(pdwVB[1]);
            FLOAT pz := DWtoF(pdwVB[2]);
            FLOAT rhw := DWtoF(pdwVB[3]);
            DWORD dwDiffuse := pdwVB[5];
            DWORD dwSpecular := pdwVB[4];
            FLOAT tx := DWtoF(pdwVB[6]);
            FLOAT ty := DWtoF(pdwVB[7]);

            //D3DFVF_POSITION_MASK

            printf('%.02d XYZ       : begin %.08f, %.08f, %.08f end;', r, px, py, pz);
            printf('%.02d RHW       : %f', r, rhw);
            printf('%.02d dwDiffuse : 0x%.08X', r, dwDiffuse);
            printf('%.02d dwSpecular: 0x%.08X', r, dwSpecular);
            printf('%.02d Tex1      : begin %.08f, %.08f end;', r, tx, ty);
            printf('');

            pdwVB:= pdwVB + (VertexStreamZeroStride/4);
         end;
     end;
    //*/

    (*
    IDirect3DBaseTexture8 *pTexture := 0;

    g_pD3DDevice8.GetTexture(0, @pTexture);

    if(pTexture <> 0) then
    begin
         Integer dwDumpTexture := 0;

         szBuffer: array [0..255-1] of Char;

        StrFmt(szBuffer, 'C:\Aaron\Textures\Texture-Active%.03d.bmp', dwDumpTexture++);

        D3DXSaveTextureToFile(szBuffer, D3DXIFF_BMP, pTexture, 0);
     end;
    //*/

    UINT PrimitiveCount := EmuD3DVertex2PrimitiveCount(PrimitiveType, VertexCount);

    // Convert from Xbox to PC enumeration
    D3DPRIMITIVETYPE PCPrimitiveType := EmuPrimitiveType(PrimitiveType);

    VertexPatchDesc VPDesc;

    VPDesc.dwVertexCount := VertexCount;
    VPDesc.PrimitiveType := PrimitiveType;
    VPDesc.dwPrimitiveCount := PrimitiveCount;
    VPDesc.dwOffset := 0;
    VPDesc.pVertexStreamZeroData := pVertexStreamZeroData;
    VPDesc.uiVertexStreamZeroStride := VertexStreamZeroStride;
    VPDesc.hVertexShader := g_CurrentVertexShader;

    VertexPatcher VertPatch;

    bool bPatched := VertPatch.Apply(@VPDesc);

    if (IsValidCurrentShader()) then
    begin
        #ifdef _DEBUG_TRACK_VB
        if( not g_bVBSkipStream) then
        begin
        //endif

        g_pD3DDevice8.DrawPrimitiveUP
        (
            PCPrimitiveType,
            VPDesc.dwPrimitiveCount,
            VPDesc.pVertexStreamZeroData,
            VPDesc.uiVertexStreamZeroStride
        );

        #ifdef _DEBUG_TRACK_VB
         end;
        //endif
     end;

    VertPatch.Restore();
    *)
  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_DrawIndexedVertices(PrimitiveType: X_D3DPRIMITIVETYPE;
  VertexCount: UINT; pIndexData: PWORD): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  dwSize: DWORD;
  hRet: HRESULT;
  pData : ^BYTE;
  PrimitiveCount : UINT;
  PCPrimitiveType : D3DPRIMITIVETYPE;
  (*VPDesc : VertexPatchDesc;
  VertPatch : VertexPatcher; *)
  bPatched : bool;
  bActiveIB : bool;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_DrawIndexedVertices' +
    #13#10'(' +
    #13#10'   PrimitiveType      : 0x%.08X' +
    #13#10'   VertexCount        : 0x%.08X' +
    #13#10'   pIndexData         : 0x%.08X' +
    #13#10');',
    [@PrimitiveType, VertexCount, pIndexData]);

    // update index buffer, if necessary

(*    if Assigned (g_pIndexBuffer) and (g_pIndexBuffer.Lock = X_D3DRESOURCE_LOCK_FLAG_NOSIZE) then
    begin
        dwSize := VertexCount*2;   // 16-bit indices

        hRet := g_pD3DDevice8.CreateIndexBuffer
        (
            dwSize, 0, D3DFMT_INDEX16, D3DPOOL_MANAGED,
            @g_pIndexBuffer.EmuIndexBuffer8
        );

        if(FAILED(hRet)) then
            CxbxKrnlCleanup('CreateIndexBuffer Failed!');

        pData := 0;
        hRet := g_pIndexBuffer.EmuIndexBuffer8.Lock(0, dwSize, @pData, 0);

        if(FAILED(hRet)) then
            CxbxKrnlCleanup('IndexBuffer Lock Failed!');

        Move ( g_pIndexBuffer.Data, pData, dwSize );

        g_pIndexBuffer.EmuIndexBuffer8.Unlock();

        g_pIndexBuffer.Data := ULONG(pData);

        hRet := g_pD3DDevice8.SetIndices(g_pIndexBuffer.EmuIndexBuffer8, g_dwBaseVertexIndex);

        if(FAILED(hRet)) then
            CxbxKrnlCleanup('SetIndices Failed!');
     end;

    EmuUpdateDeferredStates();

    if( (PrimitiveType = X_D3DPT_QUADLIST) or (PrimitiveType = X_D3DPT_QUADSTRIP) or (PrimitiveType = X_D3DPT_POLYGON) ) then
        EmuWarning('Unsupported PrimitiveType! (%d)', [DWORD(PrimitiveType)]);

    PrimitiveCount := EmuD3DVertex2PrimitiveCount(PrimitiveType, VertexCount);

    // Convert from Xbox to PC enumeration
    PCPrimitiveType := EmuPrimitiveType(PrimitiveType);


    VPDesc.dwVertexCount := VertexCount;
    VPDesc.PrimitiveType := PrimitiveType;
    VPDesc.dwPrimitiveCount := PrimitiveCount;
    VPDesc.dwOffset := 0;
    VPDesc.pVertexStreamZeroData := 0;
    VPDesc.uiVertexStreamZeroStride := 0;
    VPDesc.hVertexShader := g_CurrentVertexShader;

    bPatched := VertPatch.Apply(@VPDesc);

    {$ifdef _DEBUG_TRACK_VB}
    if( not g_bVBSkipStream) then
    begin
    {$endif}

    bActiveIB := False;
    IDirect3DIndexBuffer8 *pIndexBuffer := 0;

    // check if there is an active index buffer
    begin
        UINT BaseIndex := 0;

        g_pD3DDevice8.GetIndices(@pIndexBuffer, @BaseIndex);

        if(pIndexBuffer <> 0) then
        begin
            bActiveIB := True;
            pIndexBuffer.Release();
         end;
     end;

    UINT uiNumVertices := 0;
    UINT uiStartIndex := 0;

    // Cxbx TODO: caching (if it becomes noticably slow to recreate the buffer each time)
    if( not bActiveIB) then
    begin
        g_pD3DDevice8.CreateIndexBuffer(VertexCount*2, D3DUSAGE_WRITEONLY, D3DFMT_INDEX16, D3DPOOL_MANAGED, @pIndexBuffer);

        if(pIndexBuffer = 0) then
            CxbxKrnlCleanup('Could not create index buffer not  (%d bytes)', VertexCount*2);

        BYTE *pbData := 0;

        pIndexBuffer.Lock(0, 0, @pbData, 0);

        if(pbData = 0) then
            CxbxKrnlCleanup('Could not lock index buffer!');

        Move ( pIndexData, pbData, VertexCount*2 );

        pIndexBuffer.Unlock();

        g_pD3DDevice8.SetIndices(pIndexBuffer, 0);

        uiNumVertices := VertexCount;
        uiStartIndex := 0;
     end
    else
    begin
        uiNumVertices := ((DWORD)pIndexData)/2 + VertexCount;
        uiStartIndex := ((DWORD)pIndexData)/2;
     end;

    if(IsValidCurrentShader()) then
    begin
        g_pD3DDevice8.DrawIndexedPrimitive
        (
            PCPrimitiveType, 0, uiNumVertices, uiStartIndex, VPDesc.dwPrimitiveCount
        );
     end;

    if( not bActiveIB) then
    begin
        g_pD3DDevice8.SetIndices(0, 0);
        pIndexBuffer.Release();
     end;

    {$ifdef _DEBUG_TRACK_VB}
     end;
    {$endif}

    VertPatch.Restore();
*)
  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

procedure XTL_EmuIDirect3DDevice8_DrawIndexedVerticesUP(PrimitiveType: X_D3DPRIMITIVETYPE;
  VertexCount: UINT; pIndexData: PVOID; pVertexStreamZeroData: PVOID;
  VertexStreamZeroStride: UINT);
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_DrawIndexedVerticesUP' +
    #13#10'(' +
    #13#10'   PrimitiveType           : 0x%.08X' +
    #13#10'   VertexCount             : 0x%.08X' +
    #13#10'   pIndexData              : 0x%.08X' +
    #13#10'   pVertexStreamZeroData   : 0x%.08X' +
    #13#10'   VertexStreamZeroStride  : 0x%.08X' +
    #13#10');',
    [@PrimitiveType, VertexCount, pIndexData, pVertexStreamZeroData, VertexStreamZeroStride]);

    // update index buffer, if necessary

    if Assigned(g_pIndexBuffer) and (g_pIndexBuffer.Lock = X_D3DRESOURCE_LOCK_FLAG_NOSIZE) then
        CxbxKrnlCleanup('g_pIndexBuffer <> 0');

    Xtl_EmuUpdateDeferredStates();
    (*
    if( (PrimitiveType = X_D3DPT_QUADLIST) or (PrimitiveType = X_D3DPT_QUADSTRIP) or (PrimitiveType = X_D3DPT_POLYGON) ) then
        EmuWarning('Unsupported PrimitiveType not  (%d)', (DWORD)PrimitiveType);

    UINT PrimitiveCount := EmuD3DVertex2PrimitiveCount(PrimitiveType, VertexCount);

    // Convert from Xbox to PC enumeration
    D3DPRIMITIVETYPE PCPrimitiveType := EmuPrimitiveType(PrimitiveType);

    VertexPatchDesc VPDesc;

    VPDesc.dwVertexCount := VertexCount;
    VPDesc.PrimitiveType := PrimitiveType;
    VPDesc.dwPrimitiveCount := PrimitiveCount;
    VPDesc.dwOffset := 0;
    VPDesc.pVertexStreamZeroData := pVertexStreamZeroData;
    VPDesc.uiVertexStreamZeroStride := VertexStreamZeroStride;
    VPDesc.hVertexShader := g_CurrentVertexShader;

    VertexPatcher VertPatch;

    bool bPatched := VertPatch.Apply(@VPDesc);

    #ifdef _DEBUG_TRACK_VB
    if( not g_bVBSkipStream) then
    begin
    //endif

    if (IsValidCurrentShader()) then
    begin
        g_pD3DDevice8.DrawIndexedPrimitiveUP
        (
            PCPrimitiveType, 0, VertexCount, VPDesc.dwPrimitiveCount, pIndexData, D3DFMT_INDEX16, VPDesc.pVertexStreamZeroData, VPDesc.uiVertexStreamZeroStride
        );
     end;

    #ifdef _DEBUG_TRACK_VB
     end;
    //endif

    VertPatch.Restore();
    *)
  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetLight(Index: DWORD; pLight: D3DLIGHT8): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetLight' +
    #13#10'(' +
    #13#10'   Index              : 0x%.08X' +
    #13#10'   pLight             : 0x%.08X' +
    #13#10');',
    [Index, @pLight]);

  hRet := g_pD3DDevice8.SetLight(Index, pLight);
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_SetMaterial(pMaterial: D3DMATERIAL8): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetMaterial' +
    #13#10'(' +
    #13#10'   pMaterial          : 0x%.08X' +
    #13#10');',
    [@pMaterial]);

  hRet := g_pD3DDevice8.SetMaterial(pMaterial);
  EmuSwapFS(fsXbox);
  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_LightEnable(Index: DWORD; bEnable: LONGBOOL): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_LightEnable' +
    #13#10'(' +
    #13#10'   Index              : 0x%.08X' +
    #13#10'   bEnable            : 0x%.08X' +
    #13#10');',
    [Index, bEnable]);

  hRet := g_pD3DDevice8.LightEnable(Index, bEnable);
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

procedure EmuIDirect3DDevice8_BlockUntilVerticalBlank;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BlockUntilVerticalBlank();');
  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetRenderTarget(pRenderTarget: PX_D3DSurface;
  pNewZStencil: PX_D3DSurface): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pPCRenderTarget: IDirect3DSurface8;
  pPCNewZStencil: IDirect3DSurface8;
begin
  EmuSwapFS(fsWindows);

(*  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetRenderTarget' +
           #13#10'(' +
           #13#10'   pRenderTarget      : 0x%.08X (0x%.08X)' +
           #13#10'   pNewZStencil       : 0x%.08X (0x%.08X)' +
           #13#10');',
           [pRenderTarget, iif(pRenderTarget <> nil, pRenderTarget.EmuSurface8, nil),
           pNewZStencil,  iif(pNewZStencil <> nil, pNewZStencil.EmuSurface8, nil)]);
*)

  pPCRenderTarget := nil;
  pPCNewZStencil := nil;

  if Assigned(pRenderTarget) then
  begin
    EmuVerifyResourceIsRegistered(pRenderTarget);
    pPCRenderTarget := pRenderTarget.EmuSurface8;
  end;

  if Assigned(pNewZStencil) then
  begin
    EmuVerifyResourceIsRegistered(pNewZStencil);
    pPCNewZStencil := pNewZStencil.EmuSurface8;
  end;

  // Cxbx TODO: Follow that stencil!
  hRet := g_pD3DDevice8.SetRenderTarget(pPCRenderTarget, pPCNewZStencil);

  if FAILED(hRet) then
    EmuWarning('SetRenderTarget failed! (0x%.08X)', [hRet]);

  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_CreatePalette: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
(*(
    X_D3DPALETTESIZE    Size,
    X_D3DPalette      **ppPalette
) *)
begin
{ TODO -oDxbx: need to be translated to delphi }
(*    *ppPalette := EmuIDirect3DDevice8_CreatePalette2(Size);
*)
  Result := D3D_OK;
end;


function XTL_EmuIDirect3DDevice8_CreatePalette2(Size : X_D3DPALETTESIZE ): PX_D3DPalette;
// Branch:martin  Revision:39 Done:10 Translator:Shadow_Tj
var
  pPalette : PX_D3DPalette;
begin
    EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_CreatePalette2' +
           #13#10'(' +
           #13#10'   Size               : 0x%.08X' +
           #13#10');',
           [@Size]);

    //X_D3DPalette *pPalette := new X_D3DPalette();

    (* Integer lk[4] =
    begin
        256*SizeOf(D3DCOLOR),    // D3DPALETTE_256
        128*SizeOf(D3DCOLOR),    // D3DPALETTE_128
        64*SizeOf(D3DCOLOR),     // D3DPALETTE_64
        32*SizeOf(D3DCOLOR)      // D3DPALETTE_32
    );

    pPalette.Common := 0;
    pPalette.Lock := $8000BEEF; // emulated reference count for palettes
    pPalette.Data := (DWORD)new uint08[lk[Size]]; *)

    EmuSwapFS(fsXbox);

    Result := pPalette;
end;

function XTL_EmuIDirect3DDevice8_SetPalette( Stage : DWORD;
    pPalette : pX_D3DPalette ): HRESULT;
// Branch:martin  Revision:39 Done:90 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

    DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetPalette' +
           #13#10'(' +
           #13#10'   Stage              : 0x%.08X' +
           #13#10'   pPalette           : 0x%.08X' +
           #13#10');',
           [Stage, pPalette]);

   (*g_pD3DDevice8.SetPaletteEntries(0, (PALETTEENTRY*)(*pPalette.Data); *)

  EmuWarning('Not setting palette');

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

procedure XTL_EmuIDirect3DDevice8_SetFlickerFilter(Filter: DWord); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetFlickerFilter' +
    #13#10'(' +
    #13#10'   Filter             : 0x%.08X' +
    #13#10');',
    [Filter]);

  EmuWarning('Not setting flicker filter');
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SetSoftDisplayFilter(Enable: Boolean); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetSoftDisplayFilter' +
    #13#10'(' +
    #13#10'   Enable             : 0%10s' +
    #13#10');',
    [BoolToStr(Enable)]);

  EmuWarning('Not setting soft display filter');
  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DPalette8_Lock: HRESULT;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
(*(
    X_D3DPalette   *pThis,
    D3DCOLOR      **ppColors,
    DWORD           Flags
) *)
begin
{ TODO -oDxbx: need to be translated to delphi }
(*    *ppColors := EmuIDirect3DPalette8_Lock2(pThis, Flags);
*)
  Result := D3D_OK;
end;

(*XTL.D3DCOLOR * WINAPI XTL.EmuIDirect3DPalette8_Lock2
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj
(
    X_D3DPalette   *pThis,
    DWORD           Flags
)
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DPalette8_Lock'
         #13#10'('
         #13#10'   pThis              : 0x%.08X'
         #13#10'   Flags              : 0x%.08X'
         #13#10');',
         Flags);

  D3DCOLOR *pColors := (D3DCOLOR)pThis.Data;

  EmuSwapFS(fsXbox);

  Result := pColors;
end; *)

procedure XTL_EmuIDirect3DDevice8_GetVertexShaderSize(Handle: DWORD; pSize: UINT); stdcall;
// Branch:martin  Revision:39 Done:80 Translator:Shadow_Tj
var
  pD3DVertexShader: X_D3DVertexShader;
  pVertexShader: VERTEX_SHADER;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVertexShaderSize' +
    #13#10'(' +
    #13#10'   Handle              : 0x%.08X' +
    #13#10'   pSize               : 0x%.08X' +
    #13#10');',
    [Handle, pSize]);

  if (pSize > 0) and VshHandleIsVertexShader(Handle) then
  begin
    (*pD3DVertexShader := (X_D3DVertexShader)(Handle and $7FFFFFFF);
    pVertexShader := pD3DVertexShader.Handle;
    pSize := pVertexShader.Size; *)
  end
  else if (pSize > 0) then
  begin
    pSize := 0;
  end;

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_DeleteVertexShader(Handle: DWord); stdcall;
// Branch:martin  Revision:39 Done:2 Translator:Shadow_Tj
var
  RealHandle: DWORD;
  hRet: HRESULT;
  pD3DVertexShader: X_D3DVertexShader;
  pVertexShader: VERTEX_SHADER;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8 : EmuIDirect3DDevice8_DeleteVertexShader' +
    #13#10'(' +
    #13#10'   Handle               : 0x%.08X' +
    #13#10');',
    [Handle]);

  RealHandle := 0;

  if (VshHandleIsVertexShader(Handle)) then
  begin
      (*  pD3DVertexShader := (X_D3DVertexShader )(Handle and $7FFFFFFF);
        pVertexShader := pD3DVertexShader.Handle;

        RealHandle := pVertexShader.Handle;
        CxbxFree(pVertexShader.pDeclaration);

        if(pVertexShader.pFunction) then
        begin
            CxbxFree(pVertexShader.pFunction);
         end;

        FreeVertexDynamicPatch(pVertexShader);

        CxbxFree(pVertexShader);
        CxbxFree(pD3DVertexShader);           *)
  end;

  hRet := g_pD3DDevice8.DeleteVertexShader(RealHandle);
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_SelectVertexShaderDirect(pVAF: X_VERTEXATTRIBUTEFORMAT;
  Address: DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

    // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SelectVertexShaderDirect' +
    #13#10'(' +
    #13#10'   pVAF               : 0x%.08X' +
    #13#10'   Address            : 0x%.08X' +
    #13#10');',
    [@pVAF, Address]);

  DbgPrintf('NOT YET IMPLEMENTED!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_GetShaderConstantMode(pMode: PDWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
{$IFDEF _DEBUG_TRACE}
  EmuSwapFS(fsWindows);
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetShaderConstantMode' +
    #13#10'(' +
    #13#10'   pMode              : 0x%.08X' +
    #13#10');',
    [pMode]);
  EmuSwapFS(fsXbox);
{$ENDIF}

  if Assigned(pMode) then
    pMode^ := g_VertexShaderConstantMode;
end;

procedure XTL_EmuIDirect3DDevice8_GetVertexShader(var aHandle: DWORD); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8 (0x%.08X): EmuIDirect3DDevice8_GetVertexShader' +
    #13#10'(' +
    #13#10'   pHandle              : 0x%.08X' +
    #13#10');',
    [aHandle]);

  if aHandle <> 0 then
    {var}aHandle := g_CurrentVertexShader;

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_GetVertexShaderConstant(aRegister: Integer;
  pConstantData: DWord; ConstantCount: DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVertexShaderConstant' +
    #13#10'(' +
    #13#10'   Register           : 0x%.08X' +
    #13#10'   pConstantData      : 0x%.08X' +
    #13#10'   ConstantCount      : 0x%.08X' +
    #13#10');',
    [aRegister, pConstantData, ConstantCount]);

  hRet := g_pD3DDevice8.GetVertexShaderConstant
    (
    aRegister + 96,
    pConstantData,
    ConstantCount
    );

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetVertexShaderInputDirect(pVAF: X_VERTEXATTRIBUTEFORMAT;
  StreamCount: UINT; pStreamInputs: X_STREAMINPUT): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SelectVertexShaderDirect' +
    #13#10'(' +
    #13#10'   pVAF               : 0x%.08X' +
    #13#10'   StreamCount        : 0x%.08X' +
    #13#10'   pStreamInputs      : 0x%.08X' +
    #13#10');',
    [@pVAF, StreamCount, @pStreamInputs]);

  DbgPrintf('NOT YET IMPLEMENTED!');
  EmuSwapFS(fsXbox);
  Result := 0;
end;

function XTL_EmuIDirect3DDevice8_GetVertexShaderInput(pHandle: DWORD;
  pStreamCount: UINT; pStreamInputs: X_STREAMINPUT): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVertexShaderInput' +
    #13#10'(' +
    #13#10'   pHandle            : 0x%.08X' +
    #13#10'   pStreamCount       : 0x%.08X' +
    #13#10'   pStreamInputs      : 0x%.08X' +
    #13#10');',
    [pHandle, pStreamCount, @pStreamInputs]);

  DbgPrintf('NOT YET IMPLEMENTED!');

  EmuSwapFS(fsXbox);
  Result := 0;
end;

function XTL_EmuIDirect3DDevice8_SetVertexShaderInput(aHandle: DWORD;
  StreamCount: UINT; pStreamInputs: X_STREAMINPUT): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

    // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetVertexShaderInput' +
    #13#10'(' +
    #13#10'   Handle             : 0x%.08X' +
    #13#10'   StreamCount        : 0x%.08X' +
    #13#10'   pStreamInputs      : 0x%.08X' +
    #13#10');',
    [aHandle, StreamCount, @pStreamInputs]);

  DbgPrintf('NOT YET IMPLEMENTED!');
  EmuSwapFS(fsXbox);
  Result := 0;
end;

procedure XTL_EmuIDirect3DDevice8_RunVertexStateShader(Address: DWORD; pData: FLOAT);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

    // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_RunVertexStateShader' +
    #13#10'(' +
    #13#10'   Address             : 0x%.08X' +
    #13#10'   pData               : 0x%.08X' +
    #13#10');',
    [Address, pData]);

  DbgPrintf('NOT YET IMPLEMENTED!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_LoadVertexShaderProgram(pFunction: DWORD; Address: DWORD);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

    // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_LoadVertexShaderProgram' +
    #13#10'(' +
    #13#10'   pFunction          : 0x%.08X' +
    #13#10'   Address            : 0x%.08X' +
    #13#10');',
    [pFunction, Address]);

  DbgPrintf('NOT YET IMPLEMENTED!');

  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DDevice8_GetVertexShaderType(aHandle: DWORD; pType: PDWORD); stdcall;
// Branch:martin  Revision:39 Done:100 Translator:PatrickvL
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVertexShaderType' +
    #13#10'(' +
    #13#10'   Handle              : 0x%.08X' +
    #13#10'   pType               : 0x%.08X' +
    #13#10');',
    [aHandle, pType]);

  if Assigned(pType) and VshHandleIsVertexShader(aHandle) then
  begin
    pType^ := PVERTEX_SHADER(VshHandleGetVertexShader(aHandle).Handle)._Type;
  end;

  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_GetVertexShaderDeclaration(Handle: DWORD;
  pData: PVOID; pSizeOfData: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pVertexShader: PVERTEX_SHADER;
begin
  EmuSwapFS(fsWindows);

    // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVertexShaderDeclaration' +
    #13#10'(' +
    #13#10'   Handle              : 0x%.08X' +
    #13#10'   pData               : 0x%.08X' +
    #13#10'   pSizeOfData         : 0x%.08X' +
    #13#10');',
    [Handle, pData, pSizeOfData]);

  hRet := D3DERR_INVALIDCALL;

  (*
  if (pSizeOfData > 0) and VshHandleIsVertexShader(Handle) then
  begin
    pVertexShader := VshHandleGetVertexShader(Handle).Handle;
    if (pSizeOfData < pVertexShader.DeclarationSize or not pData) then
    begin
      pSizeOfData := pVertexShader.DeclarationSize;
      hRet := ifThen(not pData, D3D_OK, D3DERR_MOREDATA);
    end
    else
    begin
            Move ( pVertexShader.pDeclaration, pData, pVertexShader.DeclarationSize );
            hRet := D3D_OK;
    end;
  end;
  *)

  EmuSwapFS(fsXbox);
  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_GetVertexShaderFunction(aHandle: DWORD; pData: PVOID; pSizeOfData: DWORD): HRESULT;
// Branch:martin  Revision:39 Done:50 Translator:Shadow_Tj
var
  hRet: HRESULT;
  pVertexShader: VERTEX_SHADER;
begin
  EmuSwapFS(fsWindows);

  // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_GetVertexShaderFunction' +
    #13#10'(' +
    #13#10'   Handle              : 0x%.08X' +
    #13#10'   pData               : 0x%.08X' +
    #13#10'   pSizeOfData         : 0x%.08X' +
    #13#10');',
    [aHandle, pData, pSizeOfData]);

  hRet := D3DERR_INVALIDCALL;

  if (pSizeOfData > 0) and VshHandleIsVertexShader(aHandle) then
  begin
    (*
    pVertexShader := VshHandleGetVertexShader(aHandle).Handle;
    if(pSizeOfData < pVertexShader.FunctionSize or  not pData) then
    begin
      pSizeOfData := pVertexShader.FunctionSize;

      hRet := ifThen( not pData, D3D_OK, D3DERR_MOREDATA);
    end
    else
    begin
      Move ( pVertexShader.pFunction, pData, pVertexShader.FunctionSize );
      hRet := D3D_OK;
    end;
    *)
  end;


  EmuSwapFS(fsXbox);
  Result := hRet;
end;

(*function XTL_EmuIDirect3D8_AllocContiguousMemory(dwSize : SIZE_T;
   dwAllocAttributes : DWORD): PVOID;
// Branch:martin  Revision:39 Done:0 Translator:Shadow_Tj


begin
    EmuSwapFS(fsWindows);

    // debug trace
    DbgPrintf( 'EmuD3D8: EmuIDirect3D8_AllocContiguousMemory'
               #13#10'('
               #13#10'   dwSize              : 0x%.08X'
               #13#10'   dwAllocAttributes   : 0x%.08X'
               #13#10');',
               dwSize,dwAllocAttributes);

 //
    // NOTE: Kludgey (but necessary) solution:
    //
    // Since this memory must be aligned on a page boundary, we must allocate an extra page
    // so that we can return a valid page aligned pointer
    //

    PVOID pRet := CxbxMalloc(dwSize + 0x1000);

    // align to page boundary
    begin
        DWORD dwRet := (DWORD)pRet;

        dwRet:= dwRet + 0x1000 - dwRet%0x1000;

        g_AlignCache.insert(dwRet, pRet);

        pRet := (PVOID)dwRet;
     end;

    DbgPrintf('EmuD3D8: EmuIDirect3D8_AllocContiguousMemory returned 0x%.08X', pRet);

    EmuSwapFS(fsXbox);

    Result := pRet;
end;     *)

function XTL_EmuIDirect3DTexture8_GetLevelDesc(Level: UINT; pDesc: X_D3DSURFACE_DESC): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

    // debug trace
  DbgPrintf('EmuD3D8: EmuIDirect3DTexture8_GetLevelDesc' +
    #13#10'(' +
    #13#10'   Level               : 0x%.08%' +
    #13#10'   pDesc               : 0x%.08%' +
    #13#10');',
    [Level, @pDesc]);

  EmuSwapFS(fsXbox);
  Result := D3D_OK;
end;

function XTL_EmuIDirect3D8_CheckDeviceMultiSampleType(Adapter: UINT;
  DeviceType: D3DDEVTYPE; SurfaceFormat: D3DFORMAT; Windowed: LONGBOOL;
  MultiSampleType: D3DMULTISAMPLE_TYPE): HRESULT;
// Branch:martin  Revision:45 Done:70 Translator:Shadow_Tj
var
  hRet: HRESULT;
  PCSurfaceFormat: D3DFORMAT;
begin
  hRet := 0;

  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_CheckDeviceMultiSampleType' +
    #13#10'(' +
    #13#10'   Adapter             : 0x%.08X' +
    #13#10'   DeviceType          : 0x%.08X' +
    #13#10'   SurfaceFormat       : 0x%.08X' +
    #13#10'   Windowed            : 0x%.08X' +
    #13#10'   MultiSampleType     : 0x%.08X' +
    #13#10');',
    [Adapter, @DeviceType, @SurfaceFormat, Windowed, @MultiSampleType]);

  if (Adapter <> D3DADAPTER_DEFAULT) then
  begin
    EmuWarning('Adapter is not D3DADAPTER_DEFAULT, correcting!');
    Adapter := D3DADAPTER_DEFAULT;
  end;

  if (DeviceType = D3DDEVTYPE_FORCE_DWORD) then
    EmuWarning('DeviceType := D3DDEVTYPE_FORCE_DWORD');

  // Convert SurfaceFormat (Xbox->PC)
  (*PCSurfaceFormat := EmuXB2PC_D3DFormat(SurfaceFormat); *)

  // Cxbx TODO: HACK: Devices that don't support this should somehow emulate it!
  if (PCSurfaceFormat = D3DFMT_D16) then
  begin
    EmuWarning('D3DFMT_16 is an unsupported texture format!');
    PCSurfaceFormat := D3DFMT_X8R8G8B8;
  end
  else if (PCSurfaceFormat = D3DFMT_P8) then
  begin
    EmuWarning('D3DFMT_P8 is an unsupported texture format!');
    PCSurfaceFormat := D3DFMT_X8R8G8B8;
  end
  else if (PCSurfaceFormat = D3DFMT_D24S8) then
  begin
    EmuWarning('D3DFMT_D24S8 is an unsupported texture format!');
    PCSurfaceFormat := D3DFMT_X8R8G8B8;
  end;

  if (Windowed <> False) then
    Windowed := False;

   // Cxbx TODO: Convert from Xbox to PC!!
  (*if (MultiSampleType = $0011) then
    MultiSampleType := D3DMULTISAMPLE_NONE
  else
    CxbxKrnlCleanup('EmuIDirect3D8_CheckDeviceMultiSampleType Unknown MultiSampleType not  (%d)', MultiSampleType);

 // Now call the real CheckDeviceMultiSampleType with the corrected parameters.
 (* HRESULT hRet = g_pD3D8 - > CheckDeviceMultiSampleType
    (
    Adapter,
    DeviceType,
    SurfaceFormat,
    Windowed,
    MultiSampleType
    );
*)


  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3D8_GetDeviceCaps(Adapter: UINT; DeviceType: D3DDEVTYPE; pCaps: D3DCAPS8): HRESULT;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_GetDeviceCaps' +
    #13#10'(' +
    #13#10'   Adapter                  : 0x%.08X' +
    #13#10'   DeviceType               : 0x%.08X' +
    #13#10'   pCaps                    : 0x%.08X' +
    #13#10');',
    [Adapter, @DeviceType, @pCaps]);

  hRet := g_pD3D8.GetDeviceCaps(Adapter, DeviceType, pCaps);
  EmuSwapFS(fsXbox);

  Result := hRet;
end;

function XTL_EmuIDirect3D8_SetPushBufferSize(PushBufferSize: DWORD; KickOffSize: DWORD): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  hRet: HRESULT;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3D8_SetPushBufferSize' +
    #13#10'(' +
    #13#10'   PushBufferSize           : 0x%.08X' +
    #13#10'   KickOffSize              : 0x%.08X' +
    #13#10');',
    [PushBufferSize, KickOffSize]);

  hRet := D3D_OK;

  // This is a Xbox extension, meaning there is no pc counterpart.
  EmuSwapFS(fsXbox);
  Result := hRet;
end;

function XTL_EmuIDirect3DDevice8_InsertFence: DWORD; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
var
  dwRet: DWord;
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_InsertFence();');

  // Cxbx TODO: Actually implement this
  dwRet := $8000BEEF;
  EmuSwapFS(fsXbox);
  Result := dwRet;
end;

procedure XTL_EmuIDirect3DDevice8_BlockOnFence(Fence: DWord);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_BlockOnFence' +
    #13#10'(' +
    #13#10'   Fence                    : 0x%.08X' +
    #13#10');',
    [Fence]);

  // Cxbx TODO: Implement
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DResource8_BlockUntilNotBusy(pThis: PX_D3DResource);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DResource8_BlockUntilNotBusy' +
    #13#10'(' +
    #13#10'   pThis                    : 0x%.08X' +
    #13#10');',
    [pThis]);

  // Cxbx TODO: Implement
  EmuSwapFS(fsXbox);
end;

procedure XTL_EmuIDirect3DVertexBuffer8_GetDesc(pThis: PX_D3DVertexBuffer; pDesc: PD3DVERTEXBUFFER_DESC);
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DVertexBuffer8_GetDesc' +
    #13#10'(' +
    #13#10'   pThis                    : 0x%.08X' +
    #13#10'   pDesc                    : 0x%.08X' +
    #13#10');',
    [pThis, pDesc]);

  // Cxbx TODO: Implement
  EmuSwapFS(fsXbox);
end;

function XTL_EmuIDirect3DDevice8_SetScissors(Count: DWORD;
  Exclusive: BOOL; const pRects: PD3DRECT): HRESULT; stdcall;
// Branch:martin  Revision:39 Done:100 Translator:Shadow_Tj
begin
  EmuSwapFS(fsWindows);

  DbgPrintf('EmuD3D8: EmuIDirect3DDevice8_SetScissors' +
    #13#10'(' +
    #13#10'   Count                    : 0x%.08X' +
    #13#10'   Exclusive                : 0x%.08X' +
    #13#10'   pRects                   : 0x%.08X' +
    #13#10');',
    [Count, Exclusive, @pRects]);

  // Cxbx TODO: Implement

  EmuSwapFS(fsXbox);

  Result := D3D_OK;
end;

exports
  XTL_EmuD3DCleanup,
  XTL_EmuD3DInit,

  XTL_EmuIDirect3D8_CheckDeviceFormat name PatchPrefix + 'Direct3D_CheckDeviceFormat',
  XTL_EmuIDirect3D8_CreateDevice name PatchPrefix + 'Direct3D_CreateDevice',
  XTL_EmuIDirect3D8_SetPushBufferSize name PatchPrefix + 'Direct3D_SetPushBufferSize',

  XTL_EmuIDirect3DDevice8_AddRef name PatchPrefix + '_D3DDevice_AddRef@0',
  XTL_EmuIDirect3DDevice8_BeginPush name PatchPrefix + '_D3DDevice_BeginPushBuffer@4',
  XTL_EmuIDirect3DDevice8_BeginStateBlock name PatchPrefix + '_D3DDevice_BeginStateBlock@0',
  XTL_EmuIDirect3DDevice8_BeginVisibilityTest name PatchPrefix + '_D3DDevice_BeginVisibilityTest@0',
  XTL_EmuIDirect3DDevice8_BlockUntilVerticalBlank name PatchPrefix + '_D3DDevice_BlockUntilVerticalBlank@0',
  XTL_EmuIDirect3DDevice8_CreatePixelShader name PatchPrefix + '_D3DDevice_CreatePixelShader@8',
  XTL_EmuIDirect3DDevice8_CreateVertexShader name PatchPrefix + '_D3DDevice_CreateVertexShader@16',
  XTL_EmuIDirect3DDevice8_DeleteVertexShader name PatchPrefix + '_D3DDevice_DeleteVertexShader@4',
  XTL_EmuIDirect3DDevice8_DrawIndexedVertices name PatchPrefix + '_D3DDevice_DrawIndexedVertices@12',
  XTL_EmuIDirect3DDevice8_DrawVertices name PatchPrefix + '_D3DDevice_DrawVertices@12',
  XTL_EmuIDirect3DDevice8_DrawVerticesUP name PatchPrefix + '_D3DDevice_DrawVerticesUP@16',
  XTL_EmuIDirect3DDevice8_EnableOverlay name PatchPrefix + '_D3DDevice_EnableOverlay@4',
  XTL_EmuIDirect3DDevice8_EndPush name PatchPrefix + '_D3DDevice_EndPushBuffer@0',
  XTL_EmuIDirect3DDevice8_EndVisibilityTest name PatchPrefix + '_D3DDevice_EndVisibilityTest@4',
  XTL_EmuIDirect3DDevice8_GetBackBuffer2 name PatchPrefix + '_D3DDevice_GetBackBuffer2@4',
  XTL_EmuIDirect3DDevice8_GetCreationParameters name PatchPrefix + '_D3DDevice_GetCreationParameters',
  XTL_EmuIDirect3DDevice8_GetDisplayFieldStatus name PatchPrefix + '_D3DDevice_GetDisplayFieldStatus',
  XTL_EmuIDirect3DDevice8_GetOverlayUpdateStatus name PatchPrefix + '_D3DDevice_GetOverlayUpdateStatus',
  XTL_EmuIDirect3DDevice8_GetTransform name PatchPrefix + '_D3DDevice_GetTransform',
  XTL_EmuIDirect3DDevice8_GetVertexShader name PatchPrefix + '_D3DDevice_GetVertexShader',
  XTL_EmuIDirect3DDevice8_GetVertexShaderSize name PatchPrefix + '_D3DDevice_GetVertexShaderSize',
  XTL_EmuIDirect3DDevice8_GetVertexShaderType name PatchPrefix + '_D3DDevice_GetVertexShaderType',
  XTL_EmuIDirect3DDevice8_GetViewport name PatchPrefix + '_D3DDevice_GetViewport',
  XTL_EmuIDirect3DDevice8_GetViewportOffsetAndScale name PatchPrefix + '_D3DDevice_GetViewportOffsetAndScale',
  XTL_EmuIDirect3DDevice8_GetVisibilityTestResult name PatchPrefix + '_D3DDevice_GetVisibilityTestResult',
  XTL_EmuIDirect3DDevice8_InsertFence name PatchPrefix + '_D3DDevice_InsertFence',
  XTL_EmuIDirect3DDevice8_IsBusy name PatchPrefix + '_D3DDevice_IsBusy',
  XTL_EmuIDirect3DDevice8_LightEnable name PatchPrefix + '_D3DDevice_LightEnable',
  XTL_EmuIDirect3DDevice8_LoadVertexShader name PatchPrefix + '_D3DDevice_LoadVertexShader',
  XTL_EmuIDirect3DDevice8_RunPushBuffer name PatchPrefix + '_D3DDevice_RunPushBuffer',
  XTL_EmuIDirect3DDevice8_SetFlickerFilter name PatchPrefix + '_D3DDevice_SetFlickerFilter',
  XTL_EmuIDirect3DDevice8_SetLight name PatchPrefix + '_D3DDevice_SetLight',
  XTL_EmuIDirect3DDevice8_SetMaterial name PatchPrefix + '_D3DDevice_SetMaterial',
  XTL_EmuIDirect3DDevice8_SetPixelShader name PatchPrefix + '_D3DDevice_SetPixelShader',
  XTL_EmuIDirect3DDevice8_SetPixelShaderConstant name PatchPrefix + '_D3DDevice_SetPixelShaderConstant',
  XTL_EmuIDirect3DDevice8_SetRenderState_CullMode name PatchPrefix + '_D3DDevice_SetRenderState_CullMode',
  XTL_EmuIDirect3DDevice8_SetRenderState_DoNotCullUncompressed name PatchPrefix + '_D3DDevice_SetRenderState_DoNotCullUncompressed',
  XTL_EmuIDirect3DDevice8_SetRenderState_Dxt1NoiseEnable name PatchPrefix + '_D3DDevice_SetRenderState_Dxt1NoiseEnable',
  XTL_EmuIDirect3DDevice8_SetRenderState_EdgeAntiAlias name PatchPrefix + '_D3DDevice_SetRenderState_EdgeAntiAlias',
  XTL_EmuIDirect3DDevice8_SetRenderState_FillMode name PatchPrefix + '_D3DDevice_SetRenderState_FillMode',
  XTL_EmuIDirect3DDevice8_SetRenderState_FogColor name PatchPrefix + '_D3DDevice_SetRenderState_FogColor',
  XTL_EmuIDirect3DDevice8_SetRenderState_FrontFace name PatchPrefix + '_D3DDevice_SetRenderState_FrontFace',
  XTL_EmuIDirect3DDevice8_SetRenderState_LineWidth name PatchPrefix + '_D3DDevice_SetRenderState_LineWidth',
  XTL_EmuIDirect3DDevice8_SetRenderState_LogicOp name PatchPrefix + '_D3DDevice_SetRenderState_LogicOp',
  XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleAntiAlias name PatchPrefix + '_D3DDevice_SetRenderState_MultiSampleAntiAlias',
  XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleMask name PatchPrefix + '_D3DDevice_SetRenderState_MultiSampleMask',
  XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleMode name PatchPrefix + '_D3DDevice_SetRenderState_MultiSampleMode',
  XTL_EmuIDirect3DDevice8_SetRenderState_MultiSampleRenderTargetMode name PatchPrefix + '_D3DDevice_SetRenderState_MultiSampleRenderTargetMode',
  XTL_EmuIDirect3DDevice8_SetRenderState_NormalizeNormals name PatchPrefix + '_D3DDevice_SetRenderState_NormalizeNormals',
  XTL_EmuIDirect3DDevice8_SetRenderState_OcclusionCullEnable name PatchPrefix + '_D3DDevice_SetRenderState_OcclusionCullEnable',
  XTL_EmuIDirect3DDevice8_SetRenderState_PSTextureModes name PatchPrefix + '_D3DDevice_SetRenderState_PSTextureModes',
  XTL_EmuIDirect3DDevice8_SetRenderState_ShadowFunc name PatchPrefix + '_D3DDevice_SetRenderState_ShadowFunc',
  XTL_EmuIDirect3DDevice8_SetRenderState_StencilEnable name PatchPrefix + '_D3DDevice_SetRenderState_StencilEnable',
  XTL_EmuIDirect3DDevice8_SetRenderState_TextureFactor name PatchPrefix + '_D3DDevice_SetRenderState_TextureFactor',
  XTL_EmuIDirect3DDevice8_SetRenderState_VertexBlend name PatchPrefix + '_D3DDevice_SetRenderState_VertexBlend',
  XTL_EmuIDirect3DDevice8_SetRenderState_YuvEnable name PatchPrefix + '_D3DDevice_SetRenderState_YuvEnable',
  XTL_EmuIDirect3DDevice8_SetRenderState_ZBias name PatchPrefix + '_D3DDevice_SetRenderState_ZBias',
  XTL_EmuIDirect3DDevice8_SetRenderState_ZEnable name PatchPrefix + '_D3DDevice_SetRenderState_ZEnable',
  XTL_EmuIDirect3DDevice8_SetRenderTarget name PatchPrefix + '_D3DDevice_SetRenderTarget',
  XTL_EmuIDirect3DDevice8_SetScissors name PatchPrefix + '_D3DDevice_SetScissors',
  XTL_EmuIDirect3DDevice8_SetShaderConstantMode name PatchPrefix + '_D3DDevice_SetShaderConstantMode',
  XTL_EmuIDirect3DDevice8_SetSoftDisplayFilter name PatchPrefix + '_D3DDevice_SetSoftDisplayFilter',
  XTL_EmuIDirect3DDevice8_SetStreamSource name PatchPrefix + '_D3DDevice_SetStreamSource',
  XTL_EmuIDirect3DDevice8_SetTexture name PatchPrefix + '_D3DDevice_SetTexture',
  XTL_EmuIDirect3DDevice8_SetTextureState_BorderColor name PatchPrefix + '_D3DDevice_SetTextureState_BorderColor',
  XTL_EmuIDirect3DDevice8_SetTextureState_ColorKeyColor name PatchPrefix + '_D3DDevice_SetTextureState_ColorKeyColor',
  XTL_EmuIDirect3DDevice8_SetTextureState_TexCoordIndex name PatchPrefix + '_D3DDevice_SetTextureState_TexCoordIndex',
  XTL_EmuIDirect3DDevice8_SetTransform name PatchPrefix + '_D3DDevice_SetTransform',
  XTL_EmuIDirect3DDevice8_SetVertexData2f name PatchPrefix + '_D3DDevice_SetVertexData2f',
  XTL_EmuIDirect3DDevice8_SetVertexData4f name PatchPrefix + '_D3DDevice_SetVertexData4f',
  XTL_EmuIDirect3DDevice8_SetVertexShader name PatchPrefix + '_D3DDevice_SetVertexShader',
  XTL_EmuIDirect3DDevice8_SetViewport name PatchPrefix + '_D3DDevice_SetViewport',

  XTL_EmuIDirect3DDevice8_GetTile name PatchPrefix + '_D3DDevice_GetTile',
  XTL_EmuIDirect3DDevice8_SetTileNoWait name PatchPrefix + '?SetTileNoWait@D3D@@YGXKPBU_D3DTILE@@@Z',
  XTL_EmuIDirect3DDevice8_DeletePixelShader name PatchPrefix + '_D3DDevice_DeletePixelShader@4',
  XTL_EmuIDirect3DDevice8_UpdateOverlay name PatchPrefix + '_D3DDevice_UpdateOverlay';

end.


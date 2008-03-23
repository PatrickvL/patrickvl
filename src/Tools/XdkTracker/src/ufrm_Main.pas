unit ufrm_Main;

interface

uses
  // Delphi
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms,
  Dialogs, ComCtrls, Menus, ShellApi, ExtCtrls,
  // 3rd party
  jpeg,
  // DXBX
  uData, xmldom, XMLIntf, msxmldom, XMLDoc, uXml, sStatusBar, sSkinProvider,
  sSkinManager;

type
  TfrmMain = class(TForm)
    MainMenu1: TMainMenu;
    Viewxdkversion1: TMenuItem;
    Viewxdkversion2: TMenuItem;
    Help1: TMenuItem;
    About1: TMenuItem;
    VisitShadowTjwebsite1: TMenuItem;
    VisitCaustikswebsite1: TMenuItem;
    VisitCxbxForum1: TMenuItem;
    N2: TMenuItem;
    Image1: TImage;
    File2: TMenuItem;
    Exit2: TMenuItem;
    N4: TMenuItem;
    ImportGameList1: TMenuItem;
    ExportGameList1: TMenuItem;
    ImportDialog: TOpenDialog;
    ExportDialog: TSaveDialog;
    XMLDocument: TXMLDocument;
    sSkinManager1: TsSkinManager;
    sSkinProvider1: TsSkinProvider;
    StatusBar1: TsStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure Viewxdkversion2Click(Sender: TObject);
    procedure About1Click(Sender: TObject);
    procedure VisitShadowTjwebsite1Click(Sender: TObject);
    procedure VisitCaustikswebsite1Click(Sender: TObject);
    procedure VisitCxbxForum1Click(Sender: TObject);
    procedure Exit2Click(Sender: TObject);
    procedure ExportGameList1Click(Sender: TObject);
    procedure ImportGameList1Click(Sender: TObject);
  private
    { Private declarations }
    ApplicationDir: string;

    ImportList: TList;

    function SearchGameName(GameName: string): Boolean;

    procedure InsertXDKInfo(GameName, XAPILIB, XBOXKRNL, LIBCMT,
      D3D8, XGRAPHC, DSOUND, XMV: string);

    procedure LoadGameData;
    procedure SaveGameData(const aFilePath, aPublishedBy: string);

    procedure ImportGameData;
    procedure ExportGameData;
    procedure ImportXbeDump;
  public
    { Public declarations }

    XInfo: PXDKInfo;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  frmMain: TfrmMain;
  GameList: TList;

implementation

uses u_xdkversions, u_About, uConst, uPublisher, uImportGames;

{$R *.dfm}

//------------------------------------------------------------------------------

function IsWindowsVista: Boolean;
var VerInfo: TOSVersioninfo;
begin
  VerInfo.dwOSVersionInfoSize := SizeOf(TOSVersionInfo);
  GetVersionEx(VerInfo);
  Result := VerInfo.dwMajorVersion >= 6;
end;

procedure TfrmMain.Viewxdkversion2Click(Sender: TObject);
var
  lIndex: Integer;
begin
  frm_xdkversion := Tfrm_xdkversion.Create(Application);

  with frm_XdkVersion do begin
    lst_Games.Clear;

    for lIndex := 0 to GameList.count - 1 do begin
      lst_Games.Items.Add(PXDKInfo(GameList.Items[lIndex])^.GameName);
    end;
  end;

  if frm_XdkVersion.ShowModal = mrOk then
  begin

  end;

  frm_XdkVersion.Free;
end; // TfrmMain.Viewxdkversion2Click

//------------------------------------------------------------------------------

procedure TfrmMain.About1Click(Sender: TObject);
begin
  frm_About := Tfrm_About.Create(Application);

  if frm_About.ShowModal = mrOk then
  begin
  end;

  frm_About.free;
end; // TfrmMain.About1Click

//------------------------------------------------------------------------------

procedure TfrmMain.VisitShadowTjwebsite1Click(Sender: TObject);
begin
  ShellExecute(0, 'open', 'http://www.shadowtj.org', nil, nil, SW_SHOWNORMAL);
end; // TfrmMain.VisitShadowTjwebsite1Click

//------------------------------------------------------------------------------

procedure TfrmMain.VisitCaustikswebsite1Click(Sender: TObject);
begin
  ShellExecute(0, 'open', 'http://www.caustik.com/cxbx/', nil, nil, SW_SHOWNORMAL);
end; // TfrmMain.VisitCaustikswebsite1Click

//------------------------------------------------------------------------------

procedure TfrmMain.VisitCxbxForum1Click(Sender: TObject);
begin
  ShellExecute(0, 'open', 'http://forums.ngemu.com/cxbx-official-discussion/', nil, nil, SW_SHOWNORMAL);
end; // TfrmMain.VisitCxbxForum1Click

//------------------------------------------------------------------------------

procedure TfrmMain.Exit2Click(Sender: TObject);
begin
  Close;
end; // TfrmMain.Exit2Click

//------------------------------------------------------------------------------

constructor TfrmMain.Create(AOwner: TComponent);
var
  parameter: string;
begin
  inherited;
  ApplicationDir := ExtractFilePath(Application.ExeName);

  GameList := TList.Create;
  LoadGameData;

  parameter := ParamStr(1);
  if parameter = '/XBEDUMP' then
  begin
    ImportXbeDump;
  end;
end; // TfrmMain.Create

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  if IsWindowsVista then begin
    sSkinManager1.SkinningRules := [srStdForms, srThirdParty];
  end
  else begin
    sSkinManager1.SkinningRules := [srStdForms, srStdDialogs, srThirdParty];
  end;
end;

//------------------------------------------------------------------------------

destructor TfrmMain.Destroy;
begin
  SaveGameData(ApplicationDir + cGameDataFile, {aPublishedBy=} '');
  GameList.Free;
  inherited;
end; // TfrmMain.Destroy

//------------------------------------------------------------------------------

procedure TfrmMain.ExportGameData;
begin
  frm_Publisher := Tfrm_Publisher.Create(Self);

  if frm_Publisher.ShowModal = mrOk then begin

    if ExportDialog.Execute then begin
      SaveGameData(ExportDialog.FileName, frm_Publisher.edtPublisher.Text);
    end;
  end;

  frm_Publisher.Release;
end; // TfrmMain.ExportGameData

//------------------------------------------------------------------------------

procedure TfrmMain.ImportGameData;
var
  xmlRootNode: iXmlNode;
  InfoNode: iXmlNode;
  GameNode: iXmlNode;
  XDKNode: iXmlNode;
  lIndex: Integer;
  Publisher: string;
  Date: TDateTime;
  GameName: string;
begin
  if ImportDialog.Execute then begin
    ImportList := TList.Create;

    XmlDocument.Active := False;
    XmlDocument.FileName := ImportDialog.FileName;
    try begin
        XmlDocument.Active := True;
      end;
    except
      on E: EDOMParseError do begin
        MessageDlg('Error parsing the file!', mtError, [mbOk], -1);
        XmlDocument.Active := False;
      end;
      on E: Exception do begin
        XmlDocument.Active := False;
      end;
    end;

    if XmlDocument.Active then begin

      XmlRootNode := XMLDocument.DocumentElement;

      InfoNode := XmlRootNode.ChildNodes.FindNode('PublishedInfo');
      Publisher := XML_ReadString(InfoNode, 'PublishedBy');

      Date := StrToDateTime(InfoNode.ChildNodes.FindNode('Date').Text);

      InfoNode := XmlRootNode.ChildNodes.FindNode('GameList');

      GameNode := InfoNode.ChildNodes.First;
      while Assigned(GameNode) do begin
        GameName := XML_ReadString(GameNode, 'Name');

        if not SearchGameName(GameName) then begin
          New(XInfo);
          XInfo.GameName := XML_ReadString(GameNode, 'Name');
          XDKNode := GameNode.ChildNodes.FindNode('XDKVersions');
          if Assigned(XDKNode) then begin
            XInfo.XAPILIB := XML_ReadString(XDKNode, 'XAPILIB');
            XInfo.XBOXKRNL := XML_ReadString(XDKNode, 'XBOXKRNL');
            XInfo.LIBCMT := XML_ReadString(XDKNode, 'LIBCMT');
            XInfo.D3D8 := XML_ReadString(XDKNode, 'D3D8');
            XInfo.XGRAPHC := XML_ReadString(XDKNode, 'XGRAPHC');
            XInfo.DSOUND := XML_ReadString(XDKNode, 'DSOUND');
            XInfo.XMV := XML_ReadString(XDKNode, 'XMV');
          end;

          ImportList.Add(XInfo);
        end;
        GameNode := GameNode.NextSibling;
      end;

      frm_ImportGames := Tfrm_ImportGames.Create(Self);

      with frm_ImportGames do begin
        edt_Publisher.Text := Publisher;
        edt_Date.text := FormatDateTime('dd/mm/yyyy', Date);
        for lIndex := 0 to ImportList.Count - 1 do begin
          with lst_Import.Items.Add do begin
            Caption := PXDKInfo(ImportList.Items[lIndex])^.GameName;
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.XAPILIB);
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.XBOXKRNL);
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.LIBCMT);
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.D3D8);
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.XGRAPHC);
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.DSOUND);
            SubItems.Add(PXDKInfo(ImportList.Items[lIndex])^.XMV);
          end;
        end;
      end;

      if frm_ImportGames.ShowModal = mrOk then begin
        for lIndex := 0 to ImportList.Count - 1 do begin
          New(XInfo);
          XInfo.GameName := PXDKInfo(ImportList.Items[lIndex])^.GameName;
          XInfo.XAPILIB := PXDKInfo(ImportList.Items[lIndex])^.XAPILIB;
          XInfo.XBOXKRNL := PXDKInfo(ImportList.Items[lIndex])^.XBOXKRNL;
          XInfo.LIBCMT := PXDKInfo(ImportList.Items[lIndex])^.LIBCMT;
          XInfo.D3D8 := PXDKInfo(ImportList.Items[lIndex])^.D3D8;
          XInfo.XGRAPHC := PXDKInfo(ImportList.Items[lIndex])^.XGRAPHC;
          XInfo.DSOUND := PXDKInfo(ImportList.Items[lIndex])^.DSOUND;
          XInfo.XMV := PXDKInfo(ImportList.Items[lIndex])^.XMV;
          GameList.Add(XInfo);
        end;
      end;

      frm_ImportGames.Release;

      ImportList.Free;
    end;
  end;
end; // TfrmMain.ImportGameData

//------------------------------------------------------------------------------

procedure TfrmMain.LoadGameData;
var
  GameDataFilePath: string;

  XmlRoot: iXmlNode;
  GameListNode: iXmlNode;
  GameNode: iXmlNode;
  XDKNodes: iXmlNode;
begin
  GameDataFilePath := ApplicationDir + cGameDataFile;
  if FileExists(GameDataFilePath) then begin
    XMLDocument.Active := False;
    XMLDocument.LoadFromFile(GameDataFilePath);
    XMLDocument.Active := True;

    XmlRoot := XmlDocument.DocumentElement;
    GameListNode := XmlRoot.ChildNodes.FindNode('GameList');

    GameNode := GameListNode.ChildNodes.FindNode('Game');
    while Assigned(GameNode) do begin

      New(XInfo);
      XInfo.GameName := XML_ReadString(GameNode, 'Name');

      XDKNodes := GameNode.ChildNodes.FindNode('XDKVersions');

      XInfo.XAPILIB := XML_ReadString(XDKNodes, 'XAPILIB');
      XInfo.XBOXKRNL := XML_ReadString(XDKNodes, 'XBOXKRNL');
      XInfo.LIBCMT := XML_ReadString(XDKNodes, 'LIBCMT');
      XInfo.D3D8 := XML_ReadString(XDKNodes, 'D3D8');
      XInfo.XGRAPHC := XML_ReadString(XDKNodes, 'XGRAPHC');
      XInfo.DSOUND := XML_ReadString(XDKNodes, 'DSOUND');
      XInfo.XMV := XML_ReadString(XDKNodes, 'XMV');

      if XInfo.GameName <> '' then begin
        GameList.Add(XInfo);
      end;

      GameNode := GameNode.NextSibling;
    end;
  end;
end; // TfrmMain.LoadGameData

//------------------------------------------------------------------------------

procedure TfrmMain.ExportGameList1Click(Sender: TObject);
begin
  ExportGameData;
end; // TfrmMain.ExportGameList1Click

//------------------------------------------------------------------------------

procedure TfrmMain.SaveGameData(const aFilePath, aPublishedBy: string);
var
  XmlRootNode: iXmlNode;
  PublishedNode: iXmlNode;
  GameListNode: iXmlNode;
  GameNode: iXmlNode;
  XDKnode: iXmlNode;
  lIndex: Integer;
begin
  if XMLDocument.Active then begin
    XMLDocument.ChildNodes.Clear;
    XmlRootNode := XMLDocument.AddChild('XDKINFO');
    XmlRootNode.SetAttribute('Version', cXmlVersion);

    PublishedNode := XmlRootNode.AddChild('PublishedInfo');

    XML_WriteDateTime(PublishedNode, 'Date', Now);
    XML_WriteString(PublishedNode, 'PublishedBy', aPublishedBy);

    GameListNode := XmlRootNode.AddChild('GameList');

    for lIndex := 0 to GameList.Count - 1 do begin
      GameNode := GameListNode.AddChild('Game');

      XML_WriteString(GameNode, 'Name', PXDKInfo(GameList.Items[lIndex])^.GameName);
      XDKnode := GameNode.AddChild('XDKVersions');

      XML_WriteString(XDKnode, 'XAPILIB', PXDKInfo(GameList.Items[lIndex])^.XAPILIB);
      XML_WriteString(XDKnode, 'XBOXKRNL', PXDKInfo(GameList.Items[lIndex])^.XBOXKRNL);
      XML_WriteString(XDKnode, 'LIBCMT', PXDKInfo(GameList.Items[lIndex])^.LIBCMT);
      XML_WriteString(XDKnode, 'D3D8', PXDKInfo(GameList.Items[lIndex])^.D3D8);
      XML_WriteString(XDKnode, 'XGRAPHC', PXDKInfo(GameList.Items[lIndex])^.XGRAPHC);
      XML_WriteString(XDKnode, 'DSOUND', PXDKInfo(GameList.Items[lIndex])^.DSOUND);
      XML_WriteString(XDKnode, 'XMV', PXDKInfo(GameList.Items[lIndex])^.XMV);
    end;

    XMLDocument.SaveToFile(aFilePath);
  end;

end; // TfrmMain.SaveGameData
//------------------------------------------------------------------------------

procedure TfrmMain.ImportXbeDump;
var
  DumpFilePath: string;
  RootNode: iXmlNode;
  GameNode: iXmlNode;

begin
  DumpFilePath := ApplicationDir + 'Dump.dat';
  if FileExists(DumpFilePath) then begin
    XmlDocument.Active := False;
    XMLDocument.LoadFromFile(DumpFilePath);
    XmlDocument.Active := true;

    RootNode := XMLDocument.DocumentElement;

    GameNode := RootNode;

    while Assigned(GameNode) do begin

      if not SearchGameName(XML_ReadString(GameNode, 'Name')) then begin
        if Assigned(GameNode.ChildNodes.FindNode('XDKVersions')) then begin
          GameNode := GameNode.ChildNodes.FindNode('XDKVersions');
        end;

        InsertXDKInfo(XML_ReadString(GameNode, 'Name'),

          XML_ReadString(GameNode, 'XAPILIB'),
          XML_ReadString(GameNode, 'XBOXKRNL'),
          XML_ReadString(GameNode, 'LIBCMT'),
          XML_ReadString(GameNode, 'D3D8'),
          XML_ReadString(GameNode, 'XGRAPHC'),
          XML_ReadString(GameNode, 'DSOUND'),
          XML_ReadString(GameNode, 'XMV'));
      end;

      GameNode := GameNode.NextSibling;
    end;
    DeleteFile(DumpFilePath);
  end;
end; // TfrmMain.ImportXbeDump

//------------------------------------------------------------------------------

function TfrmMain.SearchGameName(GameName: string): Boolean;
var
  lIndex: Integer;
begin
  Result := False;

  for lIndex := 0 to GameList.Count - 1 do begin
    if PXDKInfo(GameList.Items[lIndex])^.GameName = GameName then begin
      Result := True;
      Break;
    end;
  end;
end; // TfrmMain.SearchGameName

//------------------------------------------------------------------------------

procedure TfrmMain.InsertXDKInfo(GameName, XAPILIB, XBOXKRNL, LIBCMT,
  D3D8, XGRAPHC, DSOUND, XMV: string);
begin
  New(XInfo);
  XInfo^.GameName := GameName;
  XInfo^.XAPILIB := XAPILIB;
  XInfo^.XBOXKRNL := XBOXKRNL;
  XInfo^.LIBCMT := LIBCMT;
  XInfo^.D3D8 := D3D8;
  XInfo^.XGRAPHC := XGRAPHC;
  XInfo^.DSOUND := DSOUND;
  XInfo^.XMV := XMV;
  GameList.Add(XInfo);
end; // TfrmMain.InsertXDKInfo

//------------------------------------------------------------------------------

procedure TfrmMain.ImportGameList1Click(Sender: TObject);
begin
  ImportGameData;
end; // TfrmMain.ImportGameList1Click

//------------------------------------------------------------------------------

end.


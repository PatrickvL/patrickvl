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
unit DxLibraryAPIScanning;

{.$DEFINE _OPTIMIZE_UNIT}

{$INCLUDE ..\Dxbx.inc}

interface

uses
  // Delphi
  Windows,
  Classes,
  SysUtils,
  // 3rd Party
  JclWin32, // UNDNAME_COMPLETE
  JclPeImage, // UndecorateSymbolName
  // Dxbx
  uTypes,
  uXBE,
  uLog,
  uStoredTrieTypes,
  uXboxLibraryUtils,
  uCRC16,
  uEmuXapi; // XTL_EmuXapiProcessHeap

type
  PPotentialLocation = ^RPotentialLocation;
  RPotentialLocation = packed record
    NextByAddress: PPotentialLocation;
    NextBySymbol: PPotentialLocation;
    StoredLibraryFunction: PStoredLibraryFunction;
    SymbolLocation: TCodePointer;
    CodeEnd: TCodePointer;
  end;

  TDetectedVersionedXboxLibrarySymbol = class(TObject)
  public
    SymbolName: string;
    XboxLibraryPatch: TXboxLibraryPatch;

    PotentialLocations: PPotentialLocation;

    StoredLibraryFunction: PStoredLibraryFunction;
    HitCount: Integer;
    SymbolLocation: TCodePointer;
    CodeEnd: TCodePointer;

    function AddPossibleLocation( const aAddress: PByte; FoundFunction: PStoredLibraryFunction): PPotentialLocation;
  end;

  TDetectedSymbols = class(TObject)
  protected
    MySymbolList: TStringList;
    function GetCount: Integer;
    function GetSymbol(Index: Integer): TDetectedVersionedXboxLibrarySymbol;
  public
    BestFitXboxLibraries: TList;

    property Count: Integer read GetCount;
    property Symbols[Index: Integer]: TDetectedVersionedXboxLibrarySymbol read GetSymbol; default;

    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    function New(const aSymbolName: string): TDetectedVersionedXboxLibrarySymbol;
    function FindByName(const aSymbolName: string): TDetectedVersionedXboxLibrarySymbol;
    function FindByAddress(const aAddress: TCodePointer): TDetectedVersionedXboxLibrarySymbol;
  end;

procedure DxbxScanForLibraryAPIs(const pLibraryVersion: PXBE_LIBRARYVERSION; const pXbeHeader: PXBE_HEADER);

var
  DetectedSymbols: TDetectedSymbols;

implementation

// Do our own demangling
function DxbxUnmangleSymbolName(const aStr: string): string;
var
  UnmangleFlags: DWord;
  i: Integer;                                    
begin
  if aStr = '' then
    Exit;

  Result := aStr;

  // Check if the symbol starts with an underscore ('_') or '@':
  case Result[1] of
    '?':
      begin
        UnmangleFlags := 0
                      // UNDNAME_COMPLETE               // Enable full undecoration
                      or UNDNAME_NO_LEADING_UNDERSCORES // Remove leading underscores from MS extended keywords
                      or UNDNAME_NO_MS_KEYWORDS         // Disable expansion of MS extended keywords
                      or UNDNAME_NO_FUNCTION_RETURNS    // Disable expansion of return type for primary declaration
                      or UNDNAME_NO_ALLOCATION_MODEL    // Disable expansion of the declaration model
                      or UNDNAME_NO_ALLOCATION_LANGUAGE // Disable expansion of the declaration language specifier
                      or UNDNAME_NO_MS_THISTYPE         // NYI Disable expansion of MS keywords on the 'this' type for primary declaration
                      or UNDNAME_NO_CV_THISTYPE         // NYI Disable expansion of CV modifiers on the 'this' type for primary declaration
                      or UNDNAME_NO_THISTYPE            // Disable all modifiers on the 'this' type
                      or UNDNAME_NO_ACCESS_SPECIFIERS   // Disable expansion of access specifiers for members
                      or UNDNAME_NO_THROW_SIGNATURES    // Disable expansion of 'throw-signatures' for functions and pointers to functions
                      or UNDNAME_NO_MEMBER_TYPE         // Disable expansion of 'static' or 'virtual'ness of members
                      or UNDNAME_NO_RETURN_UDT_MODEL    // Disable expansion of MS model for UDT returns
                      or UNDNAME_32_BIT_DECODE          // Undecorate 32-bit decorated names
                      or UNDNAME_NAME_ONLY              // Crack only the name for primary declaration;
                      or UNDNAME_NO_ARGUMENTS           // Don't undecorate arguments to function
                      or UNDNAME_NO_SPECIAL_SYMS        // Don't undecorate special names (v-table, vcall, vector xxx, metatype, etc)
                      ;

        // Do Microsoft symbol demangling :
        if not UndecorateSymbolName(aStr, {var}Result, UnmangleFlags) then
          Result := aStr;
      end;
    '_', '@':
    begin
      // Remove this leading character :
      Delete(Result, 1, 1);
      // Replace all following underscores with a dot ('.') :
      Result := StringReplace(Result, '_', '.', [rfReplaceAll]);
    end;
  end;

  // Remove everything from '@' onward :
  i := Pos('@', Result);
  if i > 1 then
    Delete(Result, i, MaxInt);

  // Replace '::' with '.' :
  Result := StringReplace(Result, '::', '.', [rfReplaceAll]);
end; // DxbxUnmangleSymbolName

{$OVERFLOWCHECKS OFF}
function DetermineRelativeAddress(const aStartingAddress: PByte; const aOffset: Word): PByte;
begin
  IntPtr(Result) := IntPtr(aStartingAddress) + IntPtr(aOffset);
  Result := PByte(IntPtr(Result) + PInteger(Result)^ + 4);
end;
{$IFDEF OVERFLOWCHECKS_ON}
  {$OVERFLOWCHECKS ON}
{$ENDIF}

{ TDetectedVersionedXboxLibrarySymbol }

function TDetectedVersionedXboxLibrarySymbol.AddPossibleLocation(
  const aAddress: PByte; FoundFunction: PStoredLibraryFunction): PPotentialLocation;
begin
  New(Result);
  Result.StoredLibraryFunction := FoundFunction;
  Result.SymbolLocation := TCodePointer(aAddress);
  Result.CodeEnd := TCodePointer(IntPtr(aAddress) + FoundFunction.FunctionLength);

  if PotentialLocations = nil then
  begin
    StoredLibraryFunction := Result.StoredLibraryFunction;
    SymbolLocation := Result.SymbolLocation;
    CodeEnd := Result.CodeEnd;
  end;

  Result.NextBySymbol := PotentialLocations;

  Inc(HitCount);
end;

function TestAddressUsingPatternTrie(const aPatternTrieReader: TPatternTrieReader; const aAddress: PByte): PStoredLibraryFunction;

  function _TryMatchingLeaf(var aStoredLibraryFunction: PStoredLibraryFunction; const aAddress: PByte): PStoredLibraryFunction;
  var
    StoredLibrary: PStoredLibrary;
    i: Integer;
    VersionedXboxLibrary: PVersionedXboxLibrary;
  begin
    Result := aStoredLibraryFunction;
{$IFDEF DXBX_RECTYPE}
    Assert(aStoredLibraryFunction.RecType = rtStoredLibraryFunction, 'StoredLibraryFunction type mismatch!');
{$ENDIF}

    // Skip to the next stored library function (including a step over all cross-references) :
    Inc(aStoredLibraryFunction);
    Inc(IntPtr({var}aStoredLibraryFunction), Result.NrCrossReferences * SizeOf(RStoredCrossReference));

    if Result.CRCLength > 0 then
    begin
      if Result.CRCValue <> CalcCRC16(aAddress, Result.CRCLength) then
      begin
        Result := nil;
        Exit;
      end;
    end;

    // TODO : Include data & test-code for : Cross-referenced APIs
    // TODO : Include data & test-code for : Trailing bytes

    // Get the Stored Library associated with this pattern :
    StoredLibrary := aPatternTrieReader.GetStoredLibrary(Result.LibraryIndex);

    // Determine if this matches one of the actual libraries :
    for i := 0 to DetectedSymbols.BestFitXboxLibraries.Count - 1 do
    begin
      VersionedXboxLibrary := DetectedSymbols.BestFitXboxLibraries[i];
      if VersionedXboxLibrary.LibVersion = StoredLibrary.LibVersion then
        if SameText(VersionedXboxLibrary.LibName, aPatternTrieReader.GetString(StoredLibrary.LibNameIndex)) then
//      if VersionedXboxLibrary.LibNameIndex = StoredLibrary.LibNameIndex then
          Exit;
    end;

    // No matching library, skip this :
    Result := nil;
  end; // _TryMatchingLeaf

  function _TryMatchingNode(aStoredTrieNode: PStoredTrieNode; aAddress: PByte; Depth: Integer): PStoredLibraryFunction;
  var
    NrChildren: Integer;
    StretchPtr: PByte;
    StretchHeaderByte: TStretchHeaderByte;
    More: Boolean;
    NrFixed, NrWildcards, i: Integer;
    NextOffset: TByteOffset;
    StoredLibraryFunction: PStoredLibraryFunction;
  begin
    Result := nil;
{$IFDEF DXBX_RECTYPE}
    Assert(aStoredTrieNode.RecType = rtStoredTrieNode, 'StoredTrieNode type mismatch!');
{$ENDIF}
    // Calculate the position of the data after this TreeNode (StretchPtr) :
    NrChildren := aStoredTrieNode.NrChildrenByte1;
    IntPtr(StretchPtr) := IntPtr(aStoredTrieNode) + SizeOf(RStoredTrieNode);
    if NrChildren >= 128 then
      // Reconstruct the NrChildren value :
      NrChildren := (Integer(aStoredTrieNode.NrChildrenByte1 and 127) shl 8) or aStoredTrieNode.NrChildrenByte2
    else
      // If one byte was sufficient, then the next stretch starts 1 byte earlier :
      Dec(IntPtr(StretchPtr), SizeOf({RStoredTrieNode.NrChildrenByte2:}Byte));

    // Scan all stretches after this node :
    repeat
      StretchHeaderByte := StretchPtr^;
      Inc(StretchPtr);

      // Determine if there are more stretches after this one :
      More := (StretchHeaderByte and NODE_FLAG_MORE) > 0;
      // Determine how many wildcard bytes need to be skipped :
      NrFixed := StretchHeaderByte shr NODE_NR_FIXED_SHIFT;
      case StretchHeaderByte and NODE_TYPE_MASK of
        NODE_5BITFIXED_4WILDCARDS: NrWildcards := 4;
        NODE_5BITFIXED_8WILDCARDS: NrWildcards := 8;
        NODE_5BITFIXED_ALLWILDCARDS:
          if (StretchHeaderByte and NODE_TYPE_MASK_EXTENDED) = NODE_ALLFIXED then
          begin
            NrFixed := PATTERNSIZE;
            NrWildcards := 0;
            More := False;
          end
          else
            NrWildcards := PATTERNSIZE - (Depth + NrFixed);
      else // NODE_5BITFIXED_0WILDCARDS:
        NrWildcards := 0;
      end;

      // Check if all fixed bytes match :
      for i := 0 to NrFixed - 1 do
      begin
        if aAddress^ <> StretchPtr^ then
          Exit;

        Inc(aAddress);
        Inc(StretchPtr);
      end;

      // If stretch was hit, update depth and search-address for the next stretch :
      Inc(Depth, NrFixed);
      Inc(Depth, NrWildcards);
      Inc(aAddress, NrWildcards);

    until not More;

    // When we're at the end of the pattern :
    if Depth >= PATTERNSIZE then
    begin
      // Handle all children leafs here, searching for the best-fit lib-version :
      StoredLibraryFunction := Pointer(StretchPtr);
      while NrChildren > 0 do
      begin
        Result := _TryMatchingLeaf({var}StoredLibraryFunction, aAddress);
        if Assigned(Result) then
          // TODO : handle all children here
          Exit;

        Dec(NrChildren);
      end;

      Exit;
    end; // if Depth

    aStoredTrieNode := Pointer(StretchPtr);
    while NrChildren > 0 do
    begin
      // Try to match pattern on this node
      Result := _TryMatchingNode(aStoredTrieNode, aAddress, Depth);
      if Assigned(Result) then
        Exit;

      // Try next child, maybe that helps:
      NextOffset := aStoredTrieNode.NextSiblingOffset;
      // Sanity-check on next-offset :
      if (NextOffset <= 0) or (NextOffset > 100*1024*1024) then
        Break;

      // Jump to next sibling :
      aStoredTrieNode := aPatternTrieReader.GetNode(NextOffset);
      Dec(NrChildren);
    end;

    Result := nil;
  end; // _TryMatchingNode

var
  Node: PStoredTrieNode;
begin
  // Search if this address matches a pattern :
  Node := aPatternTrieReader.GetNode(aPatternTrieReader.StoredSignatureTrieHeader.TrieRootNode);

  Result := _TryMatchingNode(Node, aAddress, 0);
end; // TestAddressUsingPatternTrie


procedure DxbxScanForLibraryAPIs(const pLibraryVersion: PXBE_LIBRARYVERSION; const pXbeHeader: PXBE_HEADER);
var
  ByteScanLower, ByteScanUpper: PByte;

  procedure _DetectVersionedXboxLibraries(const aPatternTrieReader: TPatternTrieReader);
  var
    CurrentXbeLibraryVersion: PXBE_LIBRARYVERSION;
    CurrentLibName: string;
    StoredLibrary, BestFit: PStoredLibrary;
    BestDist, ThisDist: Integer;
    StoredLibraryName: string;
    i, j: Integer;
    VersionedXboxLibrary: PVersionedXboxLibrary;
  begin
    // Loop over all libraries :
    CurrentXbeLibraryVersion := pLibraryVersion;
    if not Assigned(CurrentXbeLibraryVersion) then
    begin
      DbgPrintf('DxbxHLE : No XBE library versions to scan!');
      Exit;
    end;

    // Loop over all library versions in the executable:
    for i := 0 to pXbeHeader.dwLibraryVersions - 1 do
    begin
      CurrentLibName := Copy(CurrentXbeLibraryVersion.szName, 1, 8);
      DbgPrintf('DxbxHLE : Library "%s" is version %d', [CurrentLibName, CurrentXbeLibraryVersion.wBuildVersion]);

      // Find the library version in our pattern trie that best matches this :
      BestFit := nil;
      BestDist := Low(BestDist);
      for j := 0 to aPatternTrieReader.StoredSignatureTrieHeader.LibraryTable.NrOfLibraries - 1 do
      begin
        StoredLibrary := aPatternTrieReader.GetStoredLibrary(j);
        StoredLibraryName := aPatternTrieReader.GetString(StoredLibrary.LibNameIndex);

        // Only consider libraries with exactly the same name :
        if SameText(StoredLibraryName, CurrentLibName) then
        begin
          // Distance : 0 on exact hit, positive when more recent, negative when older;
          // More recent is better than older version; The closer to 0, the better.
          ThisDist := Integer(StoredLibrary.LibVersion) - Integer(CurrentXbeLibraryVersion.wBuildVersion);
          // Use this library when no other are found yet :
          if (BestFit = nil)
          // Or when the this version comes closer to the actual version :
          or (ThisDist = 0)
          or ((BestDist < 0) and (ThisDist > 0))
          or ((BestDist < 0) and (ThisDist < 0) and (ThisDist > BestDist))
          or ((BestDist > 0) and (ThisDist > 0) and (ThisDist < BestDist)) then
          begin
            BestFit := StoredLibrary;
            BestDist := ThisDist;
          end;
        end;
      end;

      if Assigned(BestFit) then
      begin
        if BestFit.LibVersion = CurrentXbeLibraryVersion.wBuildVersion then
          DbgPrintf('... Got patterns for exactly this version!')
        else
          DbgPrintf('... Approximating this with patterns from library %d.', [BestFit.LibVersion]);

        // Add this library to a list we'll use in the detection-code :
        VersionedXboxLibrary := AllocMem(SizeOf(RVersionedXboxLibrary));
{$IFDEF DXBX_RECTYPE}
        VersionedXboxLibrary.RecType := rtVersionedXboxLibrary;
{$ENDIF}
        VersionedXboxLibrary.LibVersion := BestFit.LibVersion;
        VersionedXboxLibrary.LibName := aPatternTrieReader.GetString(BestFit.LibNameIndex);
        DetectedSymbols.BestFitXboxLibraries.Add(VersionedXboxLibrary);
      end
      else
        DbgPrintf('... No patterns registered for this library!');

      // Skip to the next library :
      Inc(CurrentXbeLibraryVersion);
    end;
  end; // _DetectVersionedXboxLibraries

  function _FindAndRememberPattern(const aPatternTrieReader: TPatternTrieReader; const aAddress: PByte): PStoredLibraryFunction;

    function _HandleCrossReference(const aStartingAddress: PByte;
      const aCrossReferenceOffset: Word; const aCrossReferenceNameIndex: TStringTableIndex): Boolean;
    var
      CrossReferenceAddress: PByte;
      CrossReferenced: PStoredLibraryFunction;
    begin
(*
      // First check : Do we have a cross-reference?
      Result := (aCrossReferenceNameIndex = NO_STRING_INDEX);
      if Result then
        Exit;

      // Use aCrossReferenceOffset to determine
      // the call-location that should be checked :
      CrossReferenceAddress := DetermineRelativeAddress(aStartingAddress, aCrossReferenceOffset);

      // First check : does this address reside in the executable segment?
      if (IntPtr(CrossReferenceAddress) < IntPtr(ByteScanLower)) or (IntPtr(CrossReferenceAddress) > IntPtr(ByteScanUpper)) then
        Exit;

      // See if we can find a function on this address :
      CrossReferenced := TestAddressUsingPatternTrie(aPatternTrieReader, CrossReferenceAddress);
      if CrossReferenced = nil then
        Exit;

      // Check if this function is indeed the one mentioned, by comparing
      // the string-indexes of both functions (they should match) :
      Result := aCrossReferenceNameIndex =
                aPatternTrieReader.GetGlobalFunction(CrossReferenced.GlobalFunctionIndex).FunctionNameIndex;
*)
    end; // _HandleCrossReference

  var
    FunctionName: string;
    Detected: TDetectedVersionedXboxLibrarySymbol;
    Unmangled: string;
  begin
    // Search if this address matches a pattern :
    Result := TestAddressUsingPatternTrie(aPatternTrieReader, aAddress);
    if Result = nil then
      Exit;

    // Now that it's found, see if it was already registered :
    FunctionName := aPatternTrieReader.GetFunctionName(Result.GlobalFunctionIndex);
    Detected := DetectedSymbols.FindByName(FunctionName);
    if Assigned(Detected) then
    begin
      Detected.AddPossibleLocation(aAddress, Result);
      Exit;
    end;

(*
    // Handle a possible cross-reference check :
    if not _HandleCrossReference(aAddress, Result.CrossReference1Offset, Result.CrossReference1NameIndex) then
    begin
      Result := nil;
      Exit;
    end;
*)
    // Do our own demangling :
    Unmangled := DxbxUnmangleSymbolName(FunctionName);

    // Newly detected functions are registered here (including their range,
    // which will come in handy when debugging) :
    Detected := DetectedSymbols.New(Unmangled);
    Detected.StoredLibraryFunction := Result;
    Detected.AddPossibleLocation(aAddress, Result);

{$IFDEF DXBX_DEBUG}
    DbgPrintf('DxbxHLE : Detected at $%.8x : ''%s'' (was "%s")', [aAddress, Unmangled, FunctionName]);
    // string(XboxLibraryPatchToString(Detected.XboxLibraryPatch))
{$ENDIF}
  end; // _FindAndRememberPattern

  procedure _ScanMemoryRangeForLibraryPatterns(const ByteScanLower, ByteScanUpper: PByte;
    const aPatternTrieReader: TPatternTrieReader);
  var
    p: PByte;
  begin
{$IFDEF DXBX_DEBUG}
    DbgPrintf('DxbxHLE : Detecting functions from $%.8x to $%.8x', [ByteScanLower, ByteScanUpper]);
{$ENDIF}
    p := ByteScanLower;
    while p <> ByteScanUpper do
    begin
      try
        _FindAndRememberPattern(aPatternTrieReader, p);
      except
{$IFDEF DXBX_DEBUG}
        DbgPrintf('DxbxHLE : Exception while scanning on address $%.8x', [p]);
{$ENDIF}
      end;

      Inc(p);
    end;
  end; // _ScanMemoryRangeForLibraryPatterns

  procedure _ResolveXapiProcessHeapAddress(const aPatternTrieReader: TPatternTrieReader);
  var
    DetectedXapiInitProcess: TDetectedVersionedXboxLibrarySymbol;
    StoredLibrary: PStoredLibrary;
    ProcessHeapOffs: Integer;
  begin
    DetectedXapiInitProcess := DetectedSymbols.FindByName('XapiInitProcess');
    if Assigned(DetectedXapiInitProcess) then
    begin
      StoredLibrary := aPatternTrieReader.GetStoredLibrary(DetectedXapiInitProcess.StoredLibraryFunction.LibraryIndex);
      if Assigned(StoredLibrary) then
      begin
        // Source for these offsets is Cxbx code (HLEIntercept.cpp) and our
        // Xapi library patterns - search in the definition of _XapiInitProcess@0
        // for the offset to the '_XapiProcessHeap' cross-reference.

        if (StoredLibrary.LibVersion >= 5849) then
          ProcessHeapOffs := $51
        else if (StoredLibrary.LibVersion >= 5558) then
          ProcessHeapOffs := $51
        else if (StoredLibrary.LibVersion >= 4928) then
          ProcessHeapOffs := $44
        else if (StoredLibrary.LibVersion >= 4361) then
          ProcessHeapOffs := $3E
        else // 3911, 4034, 4134
          ProcessHeapOffs := $3E;

        XTL_EmuXapiProcessHeap := PPointer(IntPtr(DetectedXapiInitProcess.SymbolLocation) + ProcessHeapOffs)^;
{$IFDEF DXBX_DEBUG}
        DbgPrintf('DxbxHLE : Resolved XapiProcessHeap at $%.8x', [XTL_EmuXapiProcessHeap]);
{$ENDIF}
      end;
    end;
  end; // _ResolveXapiProcessHeapAddress

var
  ResourceStream: TResourceStream;
  PatternTrieReader: TPatternTrieReader;
{$IFDEF DXBX_DEBUG}
  i: Integer;
{$ENDIF}
begin
  ByteScanLower := PByte(pXbeHeader.dwBaseAddr);
  ByteScanUpper := PByte(IntPtr(ByteScanLower) + Integer(pXbeHeader.dwSizeofImage) + Integer(pXbeHeader.dwPeStackCommit));
  // Dxbx Note : Extending the scan beyond dwSizeofImage (by adding dwPeStackCommit)
  // might cause Access Violations (in which case we should probably determine
  // a more accurate boundary). The increment of the range was done to be able
  // to still capture far-away global symbols (like 'XapiProcessHeap').
  //
  // In the case of Turok, this global is located at $00269DB3, whilst code
  // ends before that at $00262420. By adding dwPeStackCommit ($00010000),
  // we stretch the window to $00272420. This seems about right, as the
  // Access Violations only start a little after that, at address $00274000.

  DetectedSymbols.Clear;

  // Get StoredPatternTrie from resource :
  ResourceStream := TResourceStream.Create(LibModuleList.ResInstance, 'StoredPatternTrie', RT_RCDATA);
  try
    PatternTrieReader := TPatternTrieReader.Create;
    try
      PatternTrieReader.LoadFromStream(ResourceStream);

      _DetectVersionedXboxLibraries(PatternTrieReader);

      // Scan Patterns using this trie :
      _ScanMemoryRangeForLibraryPatterns(ByteScanLower, ByteScanUpper, PatternTrieReader);

      // Resolve the address of _XapiProcessHeap :
      _ResolveXapiProcessHeapAddress(PatternTrieReader);

    finally
      FreeAndNil(PatternTrieReader);
    end;

  finally
    // Unlock the resource :
    FreeAndNil(ResourceStream);
  end;

{$IFDEF DXBX_DEBUG}
  // Show a list of detected functions with a HitCount > 1 :
  for i := 0 to DetectedSymbols.Count - 1 do
    if DetectedSymbols[i].HitCount > 1 then
      DbgPrintf('DxbxHLE : Duplicate %.3d hits on ''%s'' ', [DetectedSymbols[i].HitCount, DetectedSymbols[i].SymbolName]);
    // string(XboxLibraryPatchToString(Detected.XboxLibraryPatch))
{$ENDIF}
  DbgPrintf('DxbxHLE : Detected functions : %d.', [DetectedSymbols.Count]);
end; // DxbxScanForLibraryAPIs

{ TDetectedSymbols }

constructor TDetectedSymbols.Create;
begin
  inherited Create;

  MySymbolList := TStringList.Create;
  MySymbolList.Sorted := True;
  MySymbolList.Duplicates := dupIgnore;
  MySymbolList.CaseSensitive := False;

  BestFitXboxLibraries := TList.Create;
end;

destructor TDetectedSymbols.Destroy;
begin
  Clear;
  FreeAndNil(MySymbolList);
  FreeAndNil(BestFitXboxLibraries);

  inherited Destroy;
end;

function TDetectedSymbols.GetCount: Integer;
begin
  Result := MySymbolList.Count;
end;

function TDetectedSymbols.GetSymbol(Index: Integer): TDetectedVersionedXboxLibrarySymbol;
begin
  Result := TDetectedVersionedXboxLibrarySymbol(MySymbolList.Objects[Index]);
end;

procedure TDetectedSymbols.Clear;
var
  i: Integer;
  DetectedSymbol: TDetectedVersionedXboxLibrarySymbol;
begin
  if Assigned(MySymbolList) then
  begin
    for i := 0 to Count - 1 do
      Symbols[i].Free;

    MySymbolList.Clear;
  end;

  if Assigned(BestFitXboxLibraries) then
    BestFitXboxLibraries.Clear;
end;

function TDetectedSymbols.New(const aSymbolName: string): TDetectedVersionedXboxLibrarySymbol;
var
  i: Integer;
begin
  i := MySymbolList.Add(aSymbolName);
  Result := TDetectedVersionedXboxLibrarySymbol(MySymbolList.Objects[i]);
  if Assigned(Result) then
    Exit;

  Result := TDetectedVersionedXboxLibrarySymbol.Create;
  Result.SymbolName := aSymbolName;
  Result.XboxLibraryPatch := XboxFunctionNameToLibraryPatch(aSymbolName);

  MySymbolList.Objects[i] := Result;
end;

function TDetectedSymbols.FindByName(const aSymbolName: string): TDetectedVersionedXboxLibrarySymbol;
var
  i: Integer;
begin
  i := MySymbolList.IndexOf(aSymbolName);
  if i >= 0 then
    Result := Symbols[i]
  else
    Result := nil;
end;

function TDetectedSymbols.FindByAddress(const aAddress: TCodePointer): TDetectedVersionedXboxLibrarySymbol;
var
  i: Integer;
begin
  // Dxbx TODO : For speed, usse a binary search here (which needs an address-ordered collection)
  for i := 0 to Count - 1 do
  begin
    Result := Symbols[i];
    if (IntPtr(Result.SymbolLocation) <= IntPtr(aAddress)) and (IntPtr(aAddress) <= IntPtr(Result.CodeEnd)) then
      Exit;
  end;

  Result := nil;
end;

initialization

  DetectedSymbols := TDetectedSymbols.Create;

finalization

  FreeAndNil(DetectedSymbols);

end.


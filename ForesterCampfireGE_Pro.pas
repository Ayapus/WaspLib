program ForesterCampfireGE_Pro;
{$DEFINE SCRIPT_ID := '4b1f2b8b-1e6f-a66-9b6a-000000000029'}
{$DEFINE SCRIPT_REVISION := 'v5.1.1-PRO-RobustFinders-ScreenStepEast'}
{$I SRL-T/osr.simba}
{$I WaspLib/osr.simba}

// ==============================
// ====== CONFIG & CONSTANTS ====
// ==============================

const
  CAMP_UPTEXT: TStringArray = [
    'Tend-to Forester''s campfire', 'Tend to Forester''s campfire',
    'Add logs', 'Add to campfire', 'Tend-to', 'Tend', 'Add'
  ];
  ROGUES_DEN_BANK_UPTEXT: TStringArray = ['Bank Bank chest', 'Use Bank chest', 'Bank'];
  TICK_MS = 600;
  POST_SPACE_XP_TIMEOUT = 9000;
  INV_EMPTY_TIMEOUT_MS = 240000;
  HOVER_TIMEOUT = 250;

// ==============================
// ==== TYPES & ENUMS ===========
// ==============================

type
  EBonfireState = (
    STATE_INITIAL_SETUP,
    STATE_BANKING,
    STATE_WALKING_TO_FIRE,
    STATE_BURNING_LOGS,
    STATE_WAITING_FOR_BURN,
    STATE_RECOVERY,
    STATE_END_SCRIPT
  );

  TMouseIntent = (miNavigate, miHover, miInteract, miBank);

// ==============================
// ========= GLOBALS ============
// ==============================
var
  Script: TBaseScript;
  CFG_LOG_ITEM: String = 'Maple logs';
  State: EBonfireState;

  NextStatsReportTime: UInt64;
  InitialXP: Int32;
  LogsBurnt: Int32;

  FireTile: TPoint; // sentinel/flag only
  IsCurrentlyBurning: Boolean = False;

  SlotTinder, SlotLogs, InvSig: Int32;
  PREF_FAST_MOUSE: Boolean;
  PREF_SPACE_TICKS: Int32;

  // Robust finders (object + color)
  FireObj: TRSObjectV2;
  EmeraldBenedictBank: TRSObjectV2;

// ==============================
// ===== CORE SCRIPT HELPERS ====
// ==============================
procedure FMStatus(const s: String); begin WriteLn('[Status] ' + s); end;
procedure FMInfo(const s: String); begin WriteLn('[Info]   ' + s); end;
procedure FMWarn(const s: String); begin WriteLn('[Warn]   ' + s); end;
procedure FMAct(const s: String); begin WriteLn('[Action] ' + s); end;

function StateToString(s: EBonfireState): String;
begin
  case s of
    STATE_INITIAL_SETUP: Result := 'INITIAL_SETUP';
    STATE_BANKING:       Result := 'BANKING';
    STATE_WALKING_TO_FIRE: Result := 'WALKING_TO_FIRE';
    STATE_BURNING_LOGS:  Result := 'BURNING_LOGS';
    STATE_WAITING_FOR_BURN: Result := 'WAITING_FOR_BURN';
    STATE_RECOVERY:      Result := 'RECOVERY';
    STATE_END_SCRIPT:    Result := 'END_SCRIPT';
    else Result := 'UNKNOWN_STATE';
  end;
end;

procedure EnsureZoomReady();
begin
  if MM2MS.ZoomLevel = -1 then
    MM2MS.ZoomLevel := Options.GetZoomLevel();
end;

procedure EnsureXPBarReady(); begin XPBar.Open(); end;

function SafePlayerCenter(): TPoint;
begin
  try
    EnsureZoomReady();
    Result := MainScreen.GetPlayerBox().Center();
    if (Result.X <= 0) or (Result.Y <= 0) then
      raiseException('bad player center');
  except
    Result := Point(
      (MainScreen.Bounds.X1 + MainScreen.Bounds.X2) div 2,
      (MainScreen.Bounds.Y1 + MainScreen.Bounds.Y2) div 2
    );
  end;
end;

procedure WaitGameTicks(n: Int32);
var total: Int32;
begin
  total := n * TICK_MS;
  Wait(total - 40, total + 60);
end;

procedure PressSpaceOnce(); begin KeyDown(VK_SPACE); Wait(35,65); KeyUp(VK_SPACE); end;

procedure SoftRecoverCamera();
begin
  FMWarn('Action failed. Adjusting camera slightly.');
  Minimap.SetCompassAngle(Minimap.GetCompassAngle() + RandomRange(-45, 45), 15);
  Wait(400, 700);
  Options.SetZoomLevel(RandomRange(40, 75));
end;

// ===========================================
// ==== MOUSE INTENT & HUMANIZATION ==========
// ===========================================
function BoxCenter(const b: TBox): TPoint;
begin Result := Point((b.X1+b.X2) div 2, (b.Y1+b.Y2) div 2); end;

function TargetDifficulty(const box: TBox; const fromP: TPoint): Double;
var size, w, h: Int32; dist: Double;
begin
  w := Max(1, box.X2 - box.X1); h := Max(1, box.Y2 - box.Y1);
  size := w*h;
  dist := Hypot(BoxCenter(box).X - fromP.X, BoxCenter(box).Y - fromP.Y);
  Result := Max(0.45, Min((dist/300.0) * (1200.0/Max(60,size)), 2.0));
end;

procedure SetMouseProfile(intent: TMouseIntent; diff: Double);
var baseSpeed: Int32;
begin
  if PREF_FAST_MOUSE then baseSpeed := 14 else baseSpeed := 9;
  case intent of
    miNavigate:
      begin Mouse.Speed:=Max(10, Min(Round(baseSpeed + 10*(1/diff)), 26)); Mouse.Gravity:=4+Random(4); Mouse.Wind:=6+Random(6); Mouse.MissChance:=Random(2); end;
    miHover:
      begin Mouse.Speed:=Max(7, Min(Round(baseSpeed-1 + 4*(1/diff)), 14));  Mouse.Gravity:=4+Random(3); Mouse.Wind:=3+Random(4); Mouse.MissChance:=1+Random(3); end;
    miInteract, miBank:
      begin Mouse.Speed:=Max(5, Min(Round(baseSpeed-3 + 3*(1/diff)), 11));  Mouse.Gravity:=5+Random(3); Mouse.Wind:=2+Random(3); Mouse.MissChance:=0; end;
  end;
end;

function RandomPointInBox_Gauss(const b: TBox): TPoint;
var centerX, centerY, stdDevX, stdDevY: Int32;
begin
  centerX := (b.X1 + b.X2) div 2;
  centerY := (b.Y1 + b.Y2) div 2;
  stdDevX := Max(1, (b.X2 - b.X1) div 6);
  stdDevY := Max(1, (b.Y2 - b.Y1) div 6);
  Result.X := Round(SRL.GaussRand(centerX, stdDevX));
  Result.Y := Round(SRL.GaussRand(centerY, stdDevY));
  Result.X := Max(b.X1, Min(Result.X, b.X2));
  Result.Y := Max(b.Y1, Min(Result.Y, b.Y2));
end;

procedure HumanMoveTo(const box: TBox; intent: TMouseIntent);
var c, o, f: TPoint; d: Double; dwell: Int32;
begin
  c := BoxCenter(box);
  d := TargetDifficulty(box, Mouse.Position);
  SetMouseProfile(intent, d);
  o := Point(c.X + Sign(c.X - Mouse.Position.X)*RandomRange(3,8), c.Y + Sign(c.Y - Mouse.Position.Y)*RandomRange(2,6));
  Mouse.Move(o); Wait(18, 40);
  if (intent = miInteract) or (intent = miBank) or (intent = miHover) then
    f := RandomPointInBox_Gauss(box)
  else
    f := SRL.RandomPoint(box);
  Mouse.Move(f);
  Wait(150, 250);
  dwell := Max(30, Min(Round(55*d + RandomRange(-15, 25)), 140));
  Wait(dwell, dwell+20);
end;

function SafeUptextClick(const uptext: TStringArray; timeout: Int32; exact: Boolean): Boolean;
var idx: Int32;
begin
  Result := MainScreen.IsUpText(uptext, timeout, idx, exact);
  if Result then Mouse.Click(MOUSE_LEFT);
end;

// ===========================================
// ==== INVENTORY HELPERS ====================
// ===========================================
function InvSignature(): Int32;
begin
  Result := (Inventory.Count() shl 16) xor Inventory.CountItem(CFG_LOG_ITEM);
end;

procedure EnsureSlots();
begin
  if (InvSig <> InvSignature()) or (SlotTinder<0) or (SlotLogs<0) then
  begin
    FMInfo('Inventory changed, rescanning for item slots.');
    if not Inventory.FindItem('Tinderbox', SlotTinder) then SlotTinder := -1;
    if not Inventory.FindItem(CFG_LOG_ITEM, SlotLogs) then SlotLogs := -1;
    InvSig := InvSignature();
  end;
end;

procedure UseTinderOnLogs_Human();
begin
  EnsureSlots();
  if (SlotTinder<0) or (SlotLogs<0) then Exit;
  HumanMoveTo(Inventory.GetSlotBox(SlotTinder), miInteract);
  Mouse.Click(MOUSE_LEFT);
  Wait(Round(SRL.GaussRand(450, 100)));
  HumanMoveTo(Inventory.GetSlotBox(SlotLogs), miInteract);
  Mouse.Click(MOUSE_LEFT);
end;

// ===========================================
// ==== ANTIBAN & FATIGUE ====================
// ===========================================
function NextPoissonMs(lambdaPerMin: Double): Int32;
var u: Double;
begin
  u := Max(0.000001, Random());
  Result := Round( (60000.0 / lambdaPerMin) * (-ln(u)) );
end;

procedure PrimeAntibanSchedule();
begin
  Antiban.AddTask(SRL.GaussRand(NextPoissonMs(0.04), 500), @Antiban.HoverSkills);   // ~25 mins
  Antiban.AddTask(SRL.GaussRand(NextPoissonMs(0.03), 500), @Antiban.RandomRotate);  // ~33 mins
  Antiban.AddTask(SRL.GaussRand(NextPoissonMs(0.02), 500), @Antiban.AdjustZoom);    // ~50 mins
  Antiban.AddTask(SRL.GaussRand(NextPoissonMs(0.05), 500), @Antiban.RandomKeyboard);// ~20 mins
end;

procedure ApplyFatigue();
var hrs: Double; f: Double;
begin
  hrs := Script.TimeRunning.ElapsedTime() / 3600000.0;
  f   := Max(1.0, Min(1.0 + 0.10*hrs + SRL.GaussRand(0.02,0.01), 1.4));
  Mouse.Speed := Max(5, Min(Round(Mouse.Speed / f), 18));
  if Random(100) < 20 then Mouse.MissChance := Max(0, Min(Mouse.MissChance + 1, 4));
end;

procedure TAntiban.Setup(); override;
begin
  Self.Skills := [ERSSkill.FIREMAKING, ERSSkill.TOTAL];
  Self.MinZoom := 40; Self.MaxZoom := 75;
  Self.AddBreak(SRL.GaussRand(70 * ONE_MINUTE, 20 * ONE_MINUTE), SRL.GaussRand(4 * ONE_MINUTE, 2 * ONE_MINUTE), 0.3, 0.6);
  Self.AddBreak(SRL.GaussRand(5 * ONE_HOUR, 1 * ONE_HOUR), SRL.GaussRand(30 * ONE_MINUTE, 10 * ONE_MINUTE), 0.25, 0.9);
  Self.AddSleep('01:30:00', SRL.GaussRand(8 * ONE_HOUR, 1 * ONE_HOUR), 0.1, 0.98);
  PrimeAntibanSchedule();
end;

// ===========================================
// ==== SCREEN-SAFE BOX / STEP HELPERS =======
// ===========================================

function ClampToMS(const b: TBox): TBox;
var mb: TBox;
begin
  mb := MainScreen.Bounds;
  Result.X1 := Max(mb.X1, Min(b.X1, mb.X2));
  Result.Y1 := Max(mb.Y1, Min(b.Y1, mb.Y2));
  Result.X2 := Max(mb.X1, Min(b.X2, mb.X2));
  Result.Y2 := Max(mb.Y1, Min(b.Y2, mb.Y2));
end;

function BoxClamped(X1, Y1, X2, Y2: Int32): TBox;
begin
  Result := ClampToMS(Box(X1, Y1, X2, Y2));
end;

// Try to click a "Walk here" point near target; returns True if it clicked
function TryWalkHereAt(const target: TPoint): Boolean;
var
  scan: TBox;
  tries, idx: Int32;
  p: TPoint;
begin
  Result := False;
  // scan a small box around target to catch ground pixels
  scan := BoxClamped(target.X-10, target.Y-10, target.X+10, target.Y+10);

  for tries := 0 to 12 do
  begin
    p := SRL.RandomPoint(scan);
    Mouse.Move(p);
    if MainScreen.IsUpText(['Walk here'], 120, idx, False) then
    begin
      Mouse.Click(MOUSE_LEFT);
      Minimap.WaitPlayerMoving(200, 2000);
      Exit(True);
    end;
    Wait(40, 80);
  end;

  // RMB fallback
  Mouse.Click(MOUSE_RIGHT);
  if ChooseOption.Select(['Walk here']) then
  begin
    Minimap.WaitPlayerMoving(200, 2000);
    Exit(True);
  end;
end;

// Step roughly one tile east on the SCREEN (compass must be 0° so east = right)
function StepOneTileEastMS(): Boolean;
var
  pc: TPoint;
  target: TPoint;
begin
  // Keep north-up so "east" really is right
  Minimap.SetCompassAngle(0, 18);
  pc := SafePlayerCenter();

  // empirically reasonable horizontal offset for ~1 tile when zoom ~50–60
  target := Point(pc.X + 60 + RandomRange(-8, 8), pc.Y + RandomRange(-10, 10));
  Result := TryWalkHereAt(target);
end;

// ===========================================
// ==== ROBUST FINDERS (fire/bonfire/bank) ===
// ===========================================

// centroid helper (since TPointArray.Average doesn't exist)
function AveragePoint(const tpa: TPointArray): TPoint;
var
  i, n: Integer;
  sx, sy: Int64;
begin
  n := Length(tpa);
  if n = 0 then Exit(Point(0, 0));
  sx := 0; sy := 0;
  for i := 0 to n - 1 do
  begin
    sx += tpa[i].X;
    sy += tpa[i].Y;
  end;
  Result.X := Round(sx / n);
  Result.Y := Round(sy / n);
end;

procedure SetupRoguesDenFinders();
begin
  // Fire object near the den's fire pit; multiple warm palettes
  FireObj := TRSObjectV2.Setup(0.80, 2, [[21132, 30538]]);
  FireObj.SetupUpText(['Fire', 'Campfire']);
  FireObj.Finder.Colors += CTS2(2730450, 13, 0.09, 1.45); // ember reds
  FireObj.Finder.Colors += CTS2(15432,   1, 0.15, 0.01);  // bright flame
  FireObj.Finder.Colors += CTS2(3317724, 14, 0.23, 1.65); // warm reds
  FireObj.Walker := @Map.Walker;

  // Emerald Benedict as bank target
  EmeraldBenedictBank := TRSObjectV2.Setup(0.70, 5, [[21128, 30542]]);
  EmeraldBenedictBank.SetupUpText(['Emerald', 'Benedict']);
  EmeraldBenedictBank.Walker := @Map.Walker;
  EmeraldBenedictBank.Finder.Colors += CTS2(3430243, 19, 0.15, 0.81);
  EmeraldBenedictBank.Finder.Colors += CTS2(6523832, 17, 0.03, 0.89);

  Banks._AddObject(EmeraldBenedictBank); // enables Banks.WalkOpen
end;

function FindFirePointInBox(const searchBox: TBox; out p: TPoint): Boolean;
var tpa, acc, biggest: TPointArray;
    area: TBox;
begin
  Result := False;
  // clamp search to mainscreen to avoid negative coords warnings
  area := ClampToMS(searchBox);

  if SRL.FindColors(tpa, CTS2(2730450, 13, 0.09, 1.45), area) > 0 then acc += tpa;
  if SRL.FindColors(tpa, CTS2(15432,   1, 0.15, 0.01), area) > 0 then acc += tpa;
  if SRL.FindColors(tpa, CTS2(3317724, 14, 0.23, 1.65), area) > 0 then acc += tpa;

  if Length(acc) = 0 then Exit;

  biggest := acc.Cluster(1).Biggest();
  if Length(biggest) = 0 then Exit;

  p := AveragePoint(biggest);
  Result := True;
end;

// Avoid Map.TileTo* and walker functions that may not exist
function AcquireFireBox(out fireBox: TBox): Boolean;
var
  p, around: TPoint;
  search: TBox;
begin
  Result := False;

  // 1) Large scan around player
  around := SafePlayerCenter();
  search := Box(around.X-180, around.Y-180, around.X+180, around.Y+180);
  if FindFirePointInBox(search, p) then
  begin
    fireBox := BoxClamped(p.X-22, p.Y-22, p.X+22, p.Y+22);
    Exit(True);
  end;

  // 2) Fallback: object hover/walk-hover, derive box from mouse
  if FireObj.Hover() or FireObj.WalkHover() then
  begin
    if MainScreen.IsUpText(['Fire','Campfire'], 160) then
    begin
      p := Mouse.Position;
      fireBox := BoxClamped(p.X-20, p.Y-20, p.X+20, p.Y+20);
      Exit(True);
    end;
  end;
end;

function UseLogsOnFire(const logsSlot: Int32; const fireBox: TBox): Boolean;
var useUp: TStringArray;
begin
  Result := False;
  if logsSlot < 0 then Exit;

  HumanMoveTo(Inventory.GetSlotBox(logsSlot), miInteract);
  Mouse.Click(MOUSE_LEFT);
  Wait(220, 320);

  useUp := [
    'Use ' + CFG_LOG_ITEM + ' -> Fire',
    'Use ' + CFG_LOG_ITEM + ' -> fire',
    'Use ' + CFG_LOG_ITEM + ' -> Campfire',
    'Use ' + CFG_LOG_ITEM + ' -> campfire'
  ];

  // Prefer explicit "Use ... -> Fire"
  HumanMoveTo(fireBox, miInteract);
  if SafeUptextClick(useUp, 170, False) then
    Exit(True);

  // Then camp uptexts (Add/Tend), LMB then RMB fallback
  if SafeUptextClick(CAMP_UPTEXT, 160, False) then
    Exit(True);

  Mouse.Click(MOUSE_RIGHT);
  if ChooseOption.Select(CAMP_UPTEXT) then
    Exit(True);
end;

function OpenBank_RoguesDen(): Boolean;
begin
  if RSInterface.IsOpen() and not Bank.IsOpen() then
    RSInterface.Close(True);

  Result := Banks.WalkOpen();
  if Result and Bank.IsOpen() then Exit(True);

  if MainScreen.IsUpText(['Emerald','Benedict','Bank']) then
  begin
    if ChooseOption.Select(['Bank B','Bank E','Bank']) then
      Exit(WaitUntil(Bank.IsOpen(), 200, 3000));
  end;

  // Static chest area fallback (kept in case your build has it)
  HumanMoveTo(Box(220, 48, 290, 95), miBank);
  if SafeUptextClick(ROGUES_DEN_BANK_UPTEXT, 160, False) then
    Exit(WaitUntil(Bank.IsOpen(), 200, 3500));

  Result := Bank.IsOpen();
end;

// ===========================================
// ==== STATE HANDLERS =======================
// ===========================================

function GetFireScreenBox(): TBox;
var
  ok: Boolean;
begin
  ok := AcquireFireBox(Result);
  if not ok then
    Result := BoxClamped(MainScreen.Center.X-20, MainScreen.Center.Y-20, MainScreen.Center.X+20, MainScreen.Center.Y+20);
end;

procedure Handle_Banking();
var itemRec: TRSBankItem;
begin
  FMStatus('No logs, moving to bank');

  if not Bank.IsOpen() then
  begin
    if not OpenBank_RoguesDen() then
    begin
      FMWarn('Failed to open bank.');
      Exit;
    end;
  end;

  FMInfo('Bank is open');
  Wait(Round(SRL.GaussRand(450, 150)));

  itemRec := TRSBankItem.Setup(CFG_LOG_ITEM, 28, False);
  if not Bank.WithdrawItem(itemRec, True) then
  begin
    FMWarn('OUT OF LOGS. Logging out as a failsafe.');
    Bank.Close(); Wait(400, 800); Logout.ClickLogout(); TerminateScript;
    Exit;
  end;

  if not WaitUntil(Inventory.CountItem(CFG_LOG_ITEM) > 0, 120, 4000) then
  begin
    FMWarn('Logs not detected in inventory after withdraw');
    Bank.Close();
    Exit;
  end;

  Bank.Close(False);
  FMInfo('Logs withdrawn, resuming task');
end;

function FindAndUseOnNewFire_Positional(fireBox: TBox): Boolean;
begin
  EnsureSlots();
  Result := UseLogsOnFire(SlotLogs, fireBox);
  if not Result then
    FMWarn('Could not find uptext on the new fire tile.');
end;

function Handle_InitialSetup(): Boolean;
var foundUptext: Boolean; fireBox: TBox; attempts: Int32;
begin
  Result := False;
  FMStatus('No bonfire established yet. Creating the first one');

  // Normalize orientation+zoom so our 1-tile step is reliable
  Minimap.SetCompassAngle(0, 18);
  Options.SetZoomLevel(52);
  Wait(Round(SRL.GaussRand(300, 120)));

  // Move ~1 tile east using a MAINSCREEN "Walk here" click
  FMAct('Stepping 1 tile east');
  if not StepOneTileEastMS() then
    FMWarn('Step east failed; proceeding at current tile.');

  Minimap.WaitPlayerMoving(200, 2000);
  Wait(Round(SRL.GaussRand(350, 120)));

  // Light initial fire
  FMAct('Using tinderbox on logs');
  UseTinderOnLogs_Human();

  if not XPBar.WaitXP(8000, 150) then Exit(False);
  FMInfo('Successfully created a new fire');
  Wait(Round(SRL.GaussRand(800, 200)));

  // Add logs to turn it into a bonfire - improved detection
  FMAct('Using log on new fire to create bonfire');
  EnsureSlots();
  if SlotLogs < 0 then Exit(False);
  
  // Try multiple times to find and interact with the fire
  for attempts := 1 to 3 do
  begin
    FMInfo('Attempt ' + IntToStr(attempts) + ' to find fire for bonfire creation');
    
    // First try to find the fire using our detection method
    if AcquireFireBox(fireBox) then
    begin
      FMInfo('Fire detected, attempting to use logs on it');
      HumanMoveTo(Inventory.GetSlotBox(SlotLogs), miInteract);
      Mouse.Click(MOUSE_LEFT);
      Wait(Round(SRL.GaussRand(240, 80)));

      // Try to click on the fire with various uptext methods
      HumanMoveTo(fireBox, miInteract);
      
      // Try direct uptext detection first
      if SafeUptextClick(['Use ' + CFG_LOG_ITEM + ' -> Fire', 'Use ' + CFG_LOG_ITEM + ' -> fire', 'Use ' + CFG_LOG_ITEM + ' -> Campfire'], 200, False) then
      begin
        foundUptext := True;
        Break;
      end;
      
      // Try campfire uptexts
      if SafeUptextClick(CAMP_UPTEXT, 200, False) then
      begin
        foundUptext := True;
        Break;
      end;
      
      // Try right-click menu as fallback
      Mouse.Click(MOUSE_RIGHT);
      Wait(100, 200);
      if ChooseOption.Select(CAMP_UPTEXT) then
      begin
        foundUptext := True;
        Break;
      end;
    end
    else
    begin
      FMWarn('Fire not detected on attempt ' + IntToStr(attempts) + ', trying object finder');
      // Fallback to object finder
      if FireObj.Hover() or FireObj.WalkHover() then
      begin
        if MainScreen.IsUpText(['Fire', 'Campfire'], 200) then
        begin
          HumanMoveTo(Inventory.GetSlotBox(SlotLogs), miInteract);
          Mouse.Click(MOUSE_LEFT);
          Wait(Round(SRL.GaussRand(240, 80)));
          
          HumanMoveTo(BoxClamped(Mouse.Position.X-15, Mouse.Position.Y-15, Mouse.Position.X+15, Mouse.Position.Y+15), miInteract);
          if SafeUptextClick(CAMP_UPTEXT, 200, False) or ChooseOption.Select(CAMP_UPTEXT) then
          begin
            foundUptext := True;
            Break;
          end;
        end;
      end;
    end;
    
    if attempts < 3 then
    begin
      FMWarn('Failed to interact with fire, waiting and retrying...');
      Wait(Round(SRL.GaussRand(1000, 500)));
      SoftRecoverCamera();
    end;
  end;

  if not foundUptext then
  begin
    FMWarn('Failed to create bonfire after 3 attempts');
    Exit(False);
  end;

  WaitGameTicks(PREF_SPACE_TICKS);
  PressSpaceOnce();

  if not XPBar.WaitXP(8000, 180) then Exit(False);
  FMInfo('Bonfire process started successfully');

  // flag that initial setup completed
  FireTile := Point(0,0);
  Result := True;
end;

procedure Handle_WalkingToFire();
begin
  FMStatus('Moving to bonfire');

  // Use object walking/hover instead of walker/tile-based movement
  if FireObj.WalkHover() then
    Minimap.WaitPlayerMoving(300, 3000)
  else if not FireObj.Hover() then
    SoftRecoverCamera();
end;

function WaitLogBurn(timeoutMs: Int32): Boolean;
var
  startCount: Int32;
  timeout: TCountDown;
begin
  startCount := Inventory.CountItem(CFG_LOG_ITEM);
  timeout.Init(timeoutMs);
  repeat
    Wait(300, 500);
    if Inventory.CountItem(CFG_LOG_ITEM) < startCount then Exit(True);
  until timeout.IsFinished();
  Result := False;
end;

procedure Handle_Burning();
var fireBox: TBox;
begin
  FMStatus('Initiating burn session');

  if not AcquireFireBox(fireBox) then
  begin
    FMWarn('Fire not found on screen.');
    Exit;
  end;

  if not UseLogsOnFire(SlotLogs, fireBox) then
  begin
    HumanMoveTo(fireBox, miInteract);
    if not SafeUptextClick(CAMP_UPTEXT, 160, False) then
    begin
      Mouse.Click(MOUSE_RIGHT);
      if not ChooseOption.Select(CAMP_UPTEXT) then Exit;
    end;
  end;

  WaitGameTicks(PREF_SPACE_TICKS);
  PressSpaceOnce();
  Inc(Script.TotalActions);

  if WaitLogBurn(POST_SPACE_XP_TIMEOUT) then
    IsCurrentlyBurning := True
  else
    FMWarn('Bonfire burning process failed to start.');
end;

procedure Handle_Waiting_For_Burn();
begin
  FMStatus('Waiting for logs to burn');
  repeat
    if Script.ShouldStop() then Break;
    Script.DoAntiban(False, False);
    Wait(1000, 1500);
  until(Inventory.CountItem(CFG_LOG_ITEM) = 0);
  FMInfo('Inventory empty. Finishing burn cycle.');
  IsCurrentlyBurning := False;
end;

// ===========================================
// ==== CORE STATE MACHINE ===================
// ===========================================
function GetState(): EBonfireState;
var
  fb: TBox;
begin
  if Script.ShouldStop() then Exit(STATE_END_SCRIPT);

  if IsCurrentlyBurning then
    Exit(STATE_WAITING_FOR_BURN);

  if Inventory.CountItem(CFG_LOG_ITEM) = 0 then
    Exit(STATE_BANKING);

  if FireTile.X < 0 then
    Exit(STATE_INITIAL_SETUP);

  if not AcquireFireBox(fb) then
    Exit(STATE_WALKING_TO_FIRE);

  Exit(STATE_BURNING_LOGS);
end;

// ==============================
// ======== STATS REPORT ========
// ==============================
procedure BumpLogsBurntOnBankSnapshot();
var had: Int32;
begin
  had := Inventory.CountItem(CFG_LOG_ITEM);
  if had = 0 then Inc(LogsBurnt, 28)
  else if InRange(28 - had, 1, 28) then Inc(LogsBurnt, 28 - had);
end;

procedure PrintStats();
var xpGained: Int32; elapsed: UInt64; xpHr, logsHr, actionsHr: Int32;
begin
  if GetTickCount() < NextStatsReportTime then Exit;
  ApplyFatigue();
  NextStatsReportTime := GetTickCount() + 15000;
  xpGained := XPBar.Tracker.Current - InitialXP;
  elapsed := Script.TimeRunning.ElapsedTime();
  xpHr := 0; logsHr := 0; actionsHr := 0;
  if elapsed > 0 then
  begin
    xpHr := Round((xpGained * 3600000) / elapsed);
    logsHr := Round((LogsBurnt * 3600000) / elapsed);
    actionsHr := Round((Script.TotalActions * 3600000) / elapsed);
  end;
  WriteLn('===================================');
  WriteLn('           Bonfire Stats');
  WriteLn('===================================');
  WriteLn('Runtime   : ' + SRL.MsToTime(elapsed, Time_Short));
  WriteLn('Actions   : ' + ToStr(Script.TotalActions) + '  (~' + ToStr(actionsHr) + '/hr)');
  WriteLn('Logs      : ' + ToStr(LogsBurnt) + '  (~' + ToStr(logsHr) + '/hr)');
  WriteLn('XP Gain   : ' + ToStr(xpGained));
  WriteLn('XP/hr     : ' + ToStr(xpHr));
  WriteLn('===================================');
end;

// ==============================
// =========== GUI ==============
// ==============================
type
  TCampfireConfig = record(TScriptForm)
    LogSelector: TLabeledCombobox;
    infoLabel: TLabel;
    FastMouseCheck: TCheckbox;
    SpaceTicksEdit: TLabeledEdit;
  end;
var
  CampGUI: TCampfireConfig;

procedure LoadFMPreferences();
var s: String;
begin
  s := WLSettings.GetString('fm_fast_mouse');
  if s = '' then PREF_FAST_MOUSE := False else PREF_FAST_MOUSE := SameText(s, 'True');
  PREF_SPACE_TICKS := StrToIntDef(WLSettings.GetString('fm_pre_space_ticks'), 2);
end;

procedure SaveFMPreferences();
begin
  WLSettings.Put('fm_fast_mouse', CampGUI.FastMouseCheck.IsChecked());
  WLSettings.Put('fm_pre_space_ticks', StrToIntDef(CampGUI.SpaceTicksEdit.GetText(), 2));
  WLSettings.SaveConfig();
end;

procedure TCampfireConfig.StartScript(Sender: TObject); override;
var chosen: String; items: TStringArray; i: Int32; found: Boolean;
begin
  chosen := Trim(Self.LogSelector.GetText());
  items := ['Logs','Oak logs','Willow logs','Maple logs','Yew logs','Magic logs','Redwood logs'];
  found := False;
  for i := 0 to High(items) do if SameText(chosen, items[i]) then begin found := True; Break; end;
  if found then CFG_LOG_ITEM := chosen else CFG_LOG_ITEM := 'Maple logs';
  WLSettings.Put('campfire_log_item', CFG_LOG_ITEM);
  SaveFMPreferences();
  inherited;
end;

procedure TCampfireConfig.Run(); override;
var scriptSettingsTab: TTabSheet; items: TStringArray; saved: String; i, defIdx: Int32;
begin
  Self.Setup('Forester Campfire Rogues Den');
  Self.Start.setOnClick(@Self.StartScript);
  LoadFMPreferences();

  Self.AddTab('Script settings');
  scriptSettingsTab := Self.Tabs[High(Self.Tabs)];
  items := ['Logs','Oak logs','Willow logs','Maple logs','Yew logs','Magic logs','Redwood logs'];
  with Self.LogSelector do
  begin
    Create(scriptSettingsTab); SetCaption('Choose logs to burn:'); SetLeft(TControl.AdjustToDPI(40));
    SetTop(TControl.AdjustToDPI(40)); SetWidth(TControl.AdjustToDPI(240)); SetStyle(csDropDownList); AddItemArray(items);
    saved := WLSettings.GetString('campfire_log_item'); if saved = '' then saved := 'Maple logs';
    defIdx := 3; for i := 0 to High(items) do if SameText(items[i], saved) then begin defIdx := i; Break; end;
    SetItemIndex(defIdx);
  end;
  with Self.FastMouseCheck do
  begin
    Create(scriptSettingsTab); SetCaption('Use faster mouse profile'); SetLeft(Self.LogSelector.GetLeft());
    SetTop(Self.LogSelector.GetBottom() + TControl.AdjustToDPI(15)); SetChecked(PREF_FAST_MOUSE);
  end;
  with Self.SpaceTicksEdit do
  begin
    Create(scriptSettingsTab); SetCaption('Wait Ticks Before Space:'); SetLeft(Self.FastMouseCheck.GetLeft());
    SetTop(Self.FastMouseCheck.GetBottom() + TControl.AdjustToDPI(10)); SetText(IntToStr(PREF_SPACE_TICKS));
  end;
  Self.infoLabel.Create(scriptSettingsTab); Self.infoLabel.SetCaption('NOTE: Banking is locked to Rogues'' Den.');
  Self.infoLabel.SetLeft(Self.SpaceTicksEdit.GetLeft()); Self.infoLabel.SetTop(Self.SpaceTicksEdit.GetBottom() + TControl.AdjustToDPI(15));

  Self.CreateAccountManager(); Self.CreateAntibanManager(); Self.CreateWaspLibSettings(); self.CreateAPISettings();
  inherited;
end;

// ==============================
// ========== MAIN ==============
// ==============================
procedure InitializeScript();
begin
  if not RSClient.IsLoggedIn() then Login.LoginPlayer();
  FMInfo('Setting map chunk to Rogues'' Den.');
  Map.SetupChunk(ERSChunk.ROGUES_DEN.Get());
  Objects.Setup(Map.Objects(), @Map.Walker);
  NPCs.Setup(Map.NPCs(), @Map.Walker);

  // Register robust finders (fire + Emerald Benedict bank)
  SetupRoguesDenFinders();

  LoadFMPreferences();
  Script.Init(WLSettings.MaxActions, WLSettings.MaxTime);
  SetMouseProfile(miNavigate, 1.0);
  EnsureZoomReady();
  EnsureXPBarReady();
  InitialXP := XPBar.Tracker.Current;
  LogsBurnt := 0;
  NextStatsReportTime := GetTickCount() + 15000;
  FireTile := Point(-1,-1); // flag: initial setup not done
  IsCurrentlyBurning := False;
  InvSig := -1;
end;

begin
  CampGUI.Run();
  InitializeScript();

  repeat
    PrintStats();
    if Inventory.CountItem(CFG_LOG_ITEM) = 0 then BumpLogsBurntOnBankSnapshot();
    State := GetState();
    FMStatus('State: ' + StateToString(State));

    case State of
      STATE_INITIAL_SETUP:
        if not Handle_InitialSetup() then
          State := STATE_RECOVERY;
      STATE_BANKING: Handle_Banking();
      STATE_WALKING_TO_FIRE: Handle_WalkingToFire();
      STATE_BURNING_LOGS: Handle_Burning();
      STATE_WAITING_FOR_BURN: Handle_Waiting_For_Burn();
      STATE_RECOVERY: SoftRecoverCamera();
      STATE_END_SCRIPT: Break;
    end;

    Script.DoAntiban();
    Wait(220, 420);
  until Script.ShouldStop();
end.
param(
    [ValidateSet("update", "discover")]
    [string]$Mode = "update",
    [string]$GitHost = "gitlab.sankhya.com.br",
    [string[]]$RepoPaths = @(),
    [ValidateSet("stash", "hard")]
    [string]$DiscardMode = "stash",
    [switch]$VpnAutoConnect
)

# Le e escreve so em stdout um UNICO objeto JSON no final - nada de Write-Host
# solto, pra quem chama (a extensao do VS Code) conseguir parsear a saida sem
# ambiguidade. Erros inesperados tambem viram JSON (nao excecao crua), pra a
# extensao sempre receber algo parseavel.
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8

function Find-SankhyaRepos {
    # Varre os discos fixos procurando repositorios git cujo remoto 'origin'
    # aponte para o GitHostFilter. Nao desce em pastas de sistema/irrelevantes
    # (Windows, Program Files, AppData, node_modules etc) pra nao demorar
    # varrendo o disco inteiro.
    param(
        [Parameter(Mandatory)] [string]$GitHostFilter,
        [string[]]$SearchRoots,
        [int]$MaxDepth = 7
    )

    if (-not $SearchRoots -or $SearchRoots.Count -eq 0) {
        $SearchRoots = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
            ForEach-Object { $_.RootDirectory.FullName }
    }

    $excludeDirNames = @(
        'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
        '$Recycle.Bin', 'System Volume Information', 'Windows.old',
        'AppData', 'node_modules', '.git', '.vs', '.idea', 'bin', 'obj',
        'Recovery', 'PerfLogs', 'found.000', 'found.001', 'found.002'
    )

    $found = New-Object System.Collections.Generic.List[object]
    $visited = New-Object System.Collections.Generic.HashSet[string]

    foreach ($root in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push(@{ Path = (Resolve-Path -LiteralPath $root).Path; Depth = 0 })

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            $path = $current.Path
            $depth = $current.Depth

            if (-not $visited.Add($path)) { continue }

            if (Test-Path -LiteralPath (Join-Path $path ".git")) {
                $remote = $null
                try {
                    Push-Location -LiteralPath $path
                    $remote = git remote get-url origin 2>$null
                    $ok = ($LASTEXITCODE -eq 0)
                    Pop-Location
                } catch {
                    $ok = $false
                    try { Pop-Location } catch {}
                }
                if ($ok -and $remote -and $remote -like "*$GitHostFilter*") {
                    $found.Add([pscustomobject]@{ Name = Split-Path $path -Leaf; Path = $path; Remote = $remote })
                }
                continue
            }

            if ($depth -ge $MaxDepth) { continue }

            $children = $null
            try {
                $children = Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction SilentlyContinue
            } catch { continue }

            foreach ($child in $children) {
                if ($excludeDirNames -contains $child.Name) { continue }
                if ($child.Name.StartsWith('$')) { continue }
                $stack.Push(@{ Path = $child.FullName; Depth = $depth + 1 })
            }
        }
    }

    return @($found | Sort-Object Path -Unique)
}

if ($Mode -eq "discover") {
    try {
        $repos = Find-SankhyaRepos -GitHostFilter $GitHost
        [pscustomobject]@{
            ok        = $true
            repoPaths = @($repos | ForEach-Object { $_.Path })
            repoNames = @($repos | ForEach-Object { $_.Name })
        } | ConvertTo-Json -Depth 5
    } catch {
        [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 5
    }
    exit 0
}

function Test-GitHostReachable {
    param([string]$GitHostName, [int]$TimeoutMs = 3000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($GitHostName, 443, $null, $null)
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($connected -and $client.Connected) { $client.Close(); return $true }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Open-FortiClientWindow {
    # Abre a janela do FortiClient clicando no icone FIXADO NA BARRA DE TAREFAS
    # (achado via UI Automation). Lancar o .exe direto nao funciona de forma
    # confiavel quando ja existe uma instancia rodando so na bandeja.
    param([int]$WaitForWindowSeconds = 10)
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $taskbarCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")
        $taskbar = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $taskbarCond)
        if (-not $taskbar) { return $false }
        $all = $taskbar.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        $btn = $all | Where-Object { $_.Current.Name -like "*FortiClient*" } | Select-Object -First 1
        if (-not $btn) { return $false }
        $r = $btn.Current.BoundingRectangle
        $x = [int]($r.Left + $r.Width / 2)
        $y = [int]($r.Top + $r.Height / 2)
        if (-not ("SankhyaTaskbarClick" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SankhyaTaskbarClick {
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool BlockInput(bool fBlockIt);
    public const uint MOUSEEVENTF_LEFTDOWN = 0x02;
    public const uint MOUSEEVENTF_LEFTUP = 0x04;
}
"@
        }
        # Mesma protecao do clique em Conectar: trava mouse/teclado real so
        # durante o clique em si, senao o cursor sintetico pode ser desviado
        # por um movimento de mouse real acontecendo no mesmo instante.
        try {
            [SankhyaTaskbarClick]::BlockInput($true) | Out-Null
            [SankhyaTaskbarClick]::SetCursorPos($x, $y) | Out-Null
            Start-Sleep -Milliseconds 200
            [SankhyaTaskbarClick]::mouse_event([SankhyaTaskbarClick]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            Start-Sleep -Milliseconds 80
            [SankhyaTaskbarClick]::mouse_event([SankhyaTaskbarClick]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        } finally {
            [SankhyaTaskbarClick]::BlockInput($false) | Out-Null
        }
    } catch {
        return $false
    }
    $deadline = (Get-Date).AddSeconds($WaitForWindowSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Get-Process | Where-Object { $_.MainWindowTitle -like "FortiClient*" }) { return $true }
    }
    return $false
}

function Select-SankhyaGoogleAccount {
    # Se o SSO abrir a tela "Escolha uma conta" do Google, acha e clica na
    # conta do dominio sankhya pelo TEXTO (UI Automation) - funciona em
    # qualquer monitor. Nao bloqueante: se a tela nao apareceu, so retorna false.
    param([string]$AccountDomain = "sankhya.com.br")
    $browserProc = Get-Process | Where-Object {
        ($_.ProcessName -eq "chrome" -or $_.ProcessName -eq "msedge") -and
        $_.MainWindowTitle -like "*Contas do Google*"
    } | Select-Object -First 1
    if (-not $browserProc) { return $false }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        [SankhyaVpnWin32]::SetForegroundWindow($browserProc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 700
        $win = [System.Windows.Automation.AutomationElement]::FromHandle($browserProc.MainWindowHandle)
        $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        $accountEl = $all | Where-Object {
            $_.Current.ControlType.ProgrammaticName -eq "ControlType.Hyperlink" -and
            $_.Current.Name -like "*@$AccountDomain*"
        } | Select-Object -First 1
        if (-not $accountEl) { return $false }
        $r = $accountEl.Current.BoundingRectangle
        $x = [int]($r.Left + $r.Width / 2)
        $y = [int]($r.Top + $r.Height / 2)
        try {
            [SankhyaVpnWin32]::BlockInput($true) | Out-Null
            [SankhyaVpnWin32]::SetCursorPos($x, $y) | Out-Null
            Start-Sleep -Milliseconds 250
            [SankhyaVpnWin32]::mouse_event([SankhyaVpnWin32]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            Start-Sleep -Milliseconds 100
            [SankhyaVpnWin32]::mouse_event([SankhyaVpnWin32]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        } finally {
            [SankhyaVpnWin32]::BlockInput($false) | Out-Null
        }
        return $true
    } catch {
        return $false
    }
}

function Connect-SankhyaVpn {
    # Clica sozinho no botao "Conectar" da janela do FortiClient. Coordenadas
    # como PROPORCAO da AREA DE CONTEUDO (GetClientRect - exclui barra de
    # titulo, que varia por DPI/tema entre maquinas). Botao Home em (675,74),
    # Conectar mirado bem colado na borda de baixo (429,474, no proprio limite
    # limite medido ~474) - centro (462) e ate 470 ainda erraram por cima em
    # popups que renderizam maiores em outras maquinas. Repete o processo
    # inteiro ate MaxAttempts vezes se a 1a tentativa completa falhar - 2-3
    # tentativas costumam bastar, mas subiu pra 6 (~3min no pior caso) pra
    # cobrir dias em que o FortiClient/SSO demora mais, sem ficar ilimitado
    # (evita travar pra sempre se a VPN estiver mesmo fora do ar).
    param(
        [string]$GitHostName,
        [double]$HomeXRatio = (675.0 / 877.0),
        [double]$HomeYRatio = (74.0 / 675.0),
        [double]$ConnectXRatio = (429.0 / 877.0),
        [double]$ConnectYRatio = (474.0 / 675.0),
        [int]$WaitForWindowSeconds = 10,
        [int]$WaitForConnectSeconds = 25,
        [int]$MaxAttempts = 6
    )

    if (-not ("SankhyaVpnWin32" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SankhyaVpnWin32 {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool BlockInput(bool fBlockIt);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public struct POINT { public int X; public int Y; }
    public const uint MOUSEEVENTF_LEFTDOWN = 0x02;
    public const uint MOUSEEVENTF_LEFTUP = 0x04;
}
"@
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        [Console]::Error.WriteLine("[vpn] tentativa $attempt de $MaxAttempts")
        if ($attempt -gt 1) { Start-Sleep -Seconds 3 }

        $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "FortiClient*" } | Select-Object -First 1
        if (-not $proc) {
            [Console]::Error.WriteLine("[vpn] janela nao encontrada, tentando abrir via icone da barra de tarefas...")
            $openedOk = Open-FortiClientWindow -WaitForWindowSeconds $WaitForWindowSeconds
            [Console]::Error.WriteLine("[vpn] Open-FortiClientWindow retornou: $openedOk")
            if ($openedOk) {
                $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "FortiClient*" } | Select-Object -First 1
            }
        }
        if (-not $proc) { [Console]::Error.WriteLine("[vpn] sem janela apos tentar abrir - pulando tentativa"); continue }
        [Console]::Error.WriteLine("[vpn] janela achada: PID $($proc.Id) Handle $($proc.MainWindowHandle)")

        try {
            [SankhyaVpnWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
        } catch { [Console]::Error.WriteLine("[vpn] SetForegroundWindow lancou excecao: $($_.Exception.Message)"); continue }
        Start-Sleep -Milliseconds 600

        $clientRect = New-Object SankhyaVpnWin32+RECT
        [SankhyaVpnWin32]::GetClientRect($proc.MainWindowHandle, [ref]$clientRect) | Out-Null
        $w = $clientRect.Right - $clientRect.Left
        $h = $clientRect.Bottom - $clientRect.Top
        [Console]::Error.WriteLine("[vpn] client rect: ${w}x${h}")
        if ($w -lt 200 -or $h -lt 200) { [Console]::Error.WriteLine("[vpn] rect pequeno demais, pulando tentativa"); continue }

        function Send-SankhyaClick([double]$ratioX, [double]$ratioY) {
            $pt = New-Object SankhyaVpnWin32+POINT
            $pt.X = [int]($ratioX * $w)
            $pt.Y = [int]($ratioY * $h)
            [SankhyaVpnWin32]::ClientToScreen($proc.MainWindowHandle, [ref]$pt) | Out-Null
            [SankhyaVpnWin32]::SetCursorPos($pt.X, $pt.Y) | Out-Null
            Start-Sleep -Milliseconds 200
            [SankhyaVpnWin32]::mouse_event([SankhyaVpnWin32]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            Start-Sleep -Milliseconds 80
            [SankhyaVpnWin32]::mouse_event([SankhyaVpnWin32]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        }

        $alreadyConnected = $false
        try {
            [SankhyaVpnWin32]::BlockInput($true) | Out-Null
            Send-SankhyaClick $HomeXRatio $HomeYRatio
            Start-Sleep -Milliseconds 400
            if (Test-GitHostReachable -GitHostName $GitHostName) {
                $alreadyConnected = $true
            } else {
                Send-SankhyaClick $ConnectXRatio $ConnectYRatio
                [Console]::Error.WriteLine("[vpn] clique em Conectar enviado")
            }
        } finally {
            [SankhyaVpnWin32]::BlockInput($false) | Out-Null
        }

        if ($alreadyConnected) { [Console]::Error.WriteLine("[vpn] ja estava conectada"); return $true }

        $deadline = (Get-Date).AddSeconds($WaitForConnectSeconds)
        $retryDeadline = (Get-Date).AddSeconds(10)
        $sawSsoWindow = $false
        $retriedClick = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-GitHostReachable -GitHostName $GitHostName) { return $true }

            $ssoWindowOpen = Get-Process | Where-Object {
                ($_.ProcessName -eq "chrome" -or $_.ProcessName -eq "msedge") -and
                $_.MainWindowTitle -like "*Contas do Google*"
            }
            if ($ssoWindowOpen) { $sawSsoWindow = $true }

            Select-SankhyaGoogleAccount | Out-Null

            if (-not $retriedClick -and -not $sawSsoWindow -and (Get-Date) -ge $retryDeadline) {
                try {
                    [SankhyaVpnWin32]::BlockInput($true) | Out-Null
                    Send-SankhyaClick $ConnectXRatio $ConnectYRatio
                } finally {
                    [SankhyaVpnWin32]::BlockInput($false) | Out-Null
                }
                $retriedClick = $true
            }
        }
    }
    return $false
}

# ---- modo update ----

$result = [ordered]@{
    ok                 = $true
    vpnDown            = $false
    vpnAutoConnected   = $false
    updated            = @()
    discardedLocal     = @()
    stashedLocal       = @()
    skippedNoUpstream  = @()
    errors             = @()
}

if (-not $RepoPaths -or $RepoPaths.Count -eq 0) {
    $result.errors += "Nenhum repositorio configurado. Rode 'Sankhya: Descobrir Repositorios'."
    $result | ConvertTo-Json -Depth 5
    exit 0
}

if (-not (Test-GitHostReachable -GitHostName $GitHost)) {
    if ($VpnAutoConnect) {
        $result.vpnAutoConnected = Connect-SankhyaVpn -GitHostName $GitHost
    }
    if (-not (Test-GitHostReachable -GitHostName $GitHost)) {
        $result.vpnDown = $true
        $result | ConvertTo-Json -Depth 5
        exit 0
    }
}

# Avisos benignos do git no stderr (ex: conversao de LF/CRLF) nao podem virar
# erro terminante com $ErrorActionPreference = "Stop" (padrao Windows PS 5.1
# quando um programa externo escreve em stderr). Os $LASTEXITCODE abaixo ja
# cobrem as falhas reais.
$ErrorActionPreference = 'Continue'

foreach ($repo in $RepoPaths) {
    $name = Split-Path $repo -Leaf

    if (-not (Test-Path (Join-Path $repo ".git"))) {
        $result.errors += "${name}: pasta nao encontrada ou nao e repositorio git ($repo)"
        continue
    }

    try {
        Push-Location $repo

        $status = git status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) {
            $result.errors += "${name}: falha ao rodar 'git status'"
            Pop-Location
            continue
        }

        if ($status) {
            $changedFiles = ($status | ForEach-Object { $_.Trim() }) -join "; "

            if ($DiscardMode -eq "hard") {
                git reset --hard --quiet 2>$null
                $resetOk = ($LASTEXITCODE -eq 0)
                git clean -fd --quiet 2>$null
                $cleanOk = ($LASTEXITCODE -eq 0)
                if (-not ($resetOk -and $cleanOk)) {
                    $result.errors += "${name}: falha ao descartar alteracoes locais"
                    Pop-Location
                    continue
                }
                $result.discardedLocal += "${name}: descartado -> $changedFiles"
            } else {
                git stash push -u -m "auto-update $(Get-Date -Format 'yyyy-MM-dd HH:mm')" --quiet 2>$null
                if ($LASTEXITCODE -ne 0) {
                    $result.errors += "${name}: falha ao guardar alteracoes locais ('git stash')"
                    Pop-Location
                    continue
                }
                $result.stashedLocal += "${name}: guardado em stash -> $changedFiles"
            }
        }

        $beforeDescribe = git describe --tags --always 2>$null

        git fetch --all --tags --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            $result.errors += "${name}: falha no 'git fetch' (verifique VPN/credenciais)"
            Pop-Location
            continue
        }

        $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
        if (-not $upstream -or $LASTEXITCODE -ne 0) {
            $result.skippedNoUpstream += $name
            Pop-Location
            continue
        }

        $behind = git rev-list "HEAD..$upstream" --count 2>$null
        if ([int]$behind -gt 0) {
            git pull --ff-only --quiet 2>$null
            if ($LASTEXITCODE -eq 0) {
                $afterDescribe = git describe --tags --always 2>$null
                $result.updated += "${name}: $beforeDescribe -> $afterDescribe"
            } else {
                $result.errors += "${name}: 'git pull --ff-only' falhou (provavel divergencia, precisa de acao manual)"
            }
        }

        Pop-Location
    } catch {
        $result.errors += "${name}: erro inesperado - $($_.Exception.Message)"
        try { Pop-Location } catch {}
    }
}

$result | ConvertTo-Json -Depth 5

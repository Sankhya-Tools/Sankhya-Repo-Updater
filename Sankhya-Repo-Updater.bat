<# :
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Command "$SnkMode='%~1'; $SnkSelf='%~f0'; Invoke-Expression ([IO.File]::ReadAllText($SnkSelf))"
exit /b %errorlevel%
#>

# ============================================================================
#  Sankhya Repo Updater - arquivo unico
#
#  Este mesmo arquivo e um .bat (as linhas acima) e um script PowerShell (tudo
#  daqui pra baixo). O cmd so executa o bloco do topo, que chama o PowerShell
#  passando este proprio arquivo como script.
#
#  Como usar: 2 cliques. Abre uma janela que encontra sozinha os modulos na
#  pasta de projetos, deixa marcar quais atualizar, ligar a VPN automatica e
#  escolher o horario. "Salvar e instalar" grava o config.json (ao lado deste
#  arquivo) e cria a tarefa diaria + o atalho na area de trabalho.
#
#  Linha de comando (usada pela tarefa e pelo atalho):
#    /agora        atualiza e mostra o resultado (atalho da area de trabalho)
#    /agendado     atualiza em segundo plano (tarefa agendada)
#    /status       mostra o que seria feito, sem alterar nada
#    /instalar     cria tarefa + atalho com o config.json atual
#    /desinstalar  remove tarefa + atalho
#
#  Suporta GitLab e GitHub ao mesmo tempo. Cada modulo tem a sua URL:
#    - pasta nao existe -> clona
#    - pasta existe mas o 'origin' aponta para outro servidor (modulo migrado
#      do GitLab para o GitHub) -> troca o 'origin' depois de confirmar que a
#      URL nova responde
#  A conexao e testada por servidor: VPN desconectada so impede os modulos do
#  GitLab; os do GitHub continuam sendo atualizados.
#
#  Logs: %LOCALAPPDATA%\SankhyaRepoUpdater\logs\update-YYYYMM.log
#
#  IMPORTANTE: mantenha este arquivo so com caracteres ASCII (sem acentos) e
#  com quebras de linha CRLF - o Windows PowerShell 5.1 le o arquivo como ANSI.
# ============================================================================

# Modulos conhecidos e onde eles vivem hoje. Aparecem na janela para marcar
# (os que ainda nao existem na maquina sao clonados), e um modulo encontrado
# no disco apontando para o GitLab e trocado para a URL daqui sozinho quando
# ele foi migrado. Quando outro modulo migrar, basta trocar a URL dele aqui.
$KnownRepos = [ordered]@{
    'sankhyaw'              = 'https://gitlab.sankhya.com.br/erp/sankhyaw.git'
    'coletorwms'            = 'https://gitlab.sankhya.com.br/erp/modules/logistica/coletorwms.git'
    'financeiro-components' = 'https://gitlab.sankhya.com.br/erp/modules/financeiro/financeiro-components.git'
    'erpcore-module'        = 'https://github.com/sankhya-tech/erpcore-module.git'
    'mgeliv-module'         = 'https://github.com/sankhya-tech/mgeliv-module.git'
    'mgecontab-module'      = 'https://github.com/sankhya-tech/mgecontab-module.git'
    'mgewms-module'         = 'https://github.com/sankhya-tech/mgewms-module.git'
    'mgeprod-module'        = 'https://github.com/sankhya-tech/mgeprod-module.git'
    'mgeimobilizado-module' = 'https://github.com/sankhya-tech/mgeimobilizado-module.git'
}

# Repositorios cujo origin comeca com um destes sao encontrados pela busca automatica.
$RepoSearchFilters = @('gitlab.sankhya.com.br/', 'github.com/sankhya-tech/')

# Avisos benignos do git no stderr nao podem virar erro terminante; as falhas
# reais sao verificadas pelo codigo de saida de cada comando git.
$ErrorActionPreference = 'Continue'

if (-not $SnkSelf) { $SnkSelf = $PSCommandPath }
if (-not $SnkMode) { $SnkMode = '' }
$ConfigPath = Join-Path (Split-Path $SnkSelf) 'config.json'
$LogDir = Join-Path $env:LOCALAPPDATA 'SankhyaRepoUpdater\logs'

# --------------------------------- configuracao -----------------------------

function Get-UpdaterConfig {
    $defaultRoot = if (Test-Path 'C:\SK-Code') { 'C:\SK-Code' } else { Split-Path (Split-Path $SnkSelf) }
    $cfg = @{
        ReposRoot      = $defaultRoot
        Repos          = @()
        VpnHosts       = @('gitlab.sankhya.com.br')
        VpnAutoConnect = $true
        DiscardMode    = 'stash'
        TaskName       = 'Sankhya-UpdateModules'
        ScheduleTime   = '11:00'
        ShortcutName   = 'Atualizar modulos Sankhya'
        Configured     = $false
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $cfg }
    try {
        $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        return $cfg
    }

    $props = @($j.PSObject.Properties.Name)
    if ($props -contains 'reposRoot' -and $j.reposRoot) { $cfg.ReposRoot = $j.reposRoot }
    if ($props -contains 'vpnAutoConnect') { $cfg.VpnAutoConnect = [bool]$j.vpnAutoConnect }
    if ($props -contains 'discardMode' -and $j.discardMode) { $cfg.DiscardMode = $j.discardMode }
    if ($props -contains 'scheduleTime' -and $j.scheduleTime) { $cfg.ScheduleTime = $j.scheduleTime }
    if ($props -contains 'taskName' -and $j.taskName) { $cfg.TaskName = $j.taskName }
    if ($props -contains 'shortcutName' -and $j.shortcutName) { $cfg.ShortcutName = $j.shortcutName }

    if ($props -contains 'repos') {
        $cfg.Repos = @($j.repos | Where-Object { $_.path } | ForEach-Object { @{ Name = $_.path; Url = $_.url } })
    } else {
        # config.json da versao antiga (repoPaths / reposRoot + repoNames)
        $paths = if ($props -contains 'repoPaths' -and @($j.repoPaths).Count -gt 0) {
            @($j.repoPaths)
        } elseif ($j.reposRoot -and $j.repoNames) {
            @($j.repoNames | ForEach-Object { Join-Path $j.reposRoot $_ })
        } else { @() }
        $cfg.Repos = @($paths | ForEach-Object {
            $leaf = Split-Path $_ -Leaf
            @{ Name = $_; Url = $(if ($KnownRepos.Contains($leaf)) { $KnownRepos[$leaf] } else { $null }) }
        })
    }
    $cfg.Configured = $true
    return $cfg
}

function Save-UpdaterConfig {
    param([string]$ReposRoot, [object[]]$Repos, [bool]$VpnAutoConnect, [string]$ScheduleTime, [string]$DiscardMode)
    $obj = [ordered]@{
        reposRoot      = $ReposRoot
        vpnAutoConnect = $VpnAutoConnect
        scheduleTime   = $ScheduleTime
        discardMode    = $DiscardMode
        taskName       = $Config.TaskName
        shortcutName   = $Config.ShortcutName
        repos          = @($Repos | ForEach-Object { [ordered]@{ path = $_.Path; url = $_.Url } })
    }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

    $fresh = Get-UpdaterConfig
    foreach ($k in @($fresh.Keys)) { $Config[$k] = $fresh[$k] }
}

$Config = Get-UpdaterConfig

# ------------------------------ utilitarios git -----------------------------

function Get-RepoList {
    foreach ($r in $Config.Repos) {
        $path = if ([IO.Path]::IsPathRooted($r.Name)) { $r.Name } else { Join-Path $Config.ReposRoot $r.Name }
        [pscustomobject]@{
            Name   = Split-Path $path -Leaf
            Path   = $path
            Url    = $r.Url
            Branch = $r.Branch
        }
    }
}

function Get-UrlHost {
    param([string]$Url)
    if (-not $Url) { return $null }
    if ($Url -match '^[a-zA-Z]:[\\/]' -or $Url -match '^\\\\') { return $null }   # caminho local / de rede
    if ($Url -match '^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^@/]+@)?([^/:]+)') { return $Matches[1].ToLower() }
    if ($Url -match '^(?:[^@/]+@)?([^:/]+):') { return $Matches[1].ToLower() }   # git@host:grupo/repo.git
    return $null
}

function ConvertTo-UrlKey {
    # Forma comparavel de uma URL git: sem protocolo, usuario, ".git" e barra final,
    # e com "host:grupo" (ssh) virando "host/grupo".
    param([string]$Url)
    if (-not $Url) { return '' }
    $u = $Url.Trim().ToLower() -replace '\\', '/'
    if ($u -match '^[a-z]:/') { return ($u -replace '/+$', '' -replace '\.git$', '') }
    $u = $u -replace '^[a-z][a-z0-9+.-]*://', '' -replace '^[^@/]+@', ''
    $u = $u -replace '^([^/:]+):(?!\d)', '$1/'
    $u = $u -replace '/+$', '' -replace '\.git$', ''
    return $u
}

function Get-ServerLabel {
    param([string]$Url)
    $h = Get-UrlHost $Url
    if (-not $h) { return '' }
    if ($h -eq 'github.com') { return 'GitHub' }
    if ($h -like 'gitlab*') { return 'GitLab' }
    return $h
}

function Invoke-Git {
    param([string]$Repo, [string[]]$GitArgs)
    $allArgs = if ($Repo) { @('-C', $Repo) + $GitArgs } else { $GitArgs }
    $out = & git @allArgs 2>&1 | ForEach-Object { "$_" }
    $ok = ($LASTEXITCODE -eq 0)
    [pscustomobject]@{ Ok = $ok; Text = ((@($out) -join "`n").Trim()) }
}

function Get-RepoOrigin {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return '' }
    $r = Invoke-Git $Path @('remote', 'get-url', 'origin')
    if ($r.Ok) { return $r.Text }
    return ''
}

function Get-ShortGitError {
    param([string]$Text)
    $lines = @($Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $fatal = $lines | Where-Object { $_ -match '^(fatal|error|remote):' } | Select-Object -Last 1
    if ($fatal) { return $fatal }
    if ($lines.Count -gt 0) { return $lines[-1] }
    return 'sem detalhes'
}

function Test-GitHostReachable {
    param([string]$GitHostName, [int]$TimeoutMs = 3000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($GitHostName, 443, $null, $null)
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($connected -and $client.Connected) {
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Find-SankhyaRepos {
    # Procura pastas com repositorio git cujo origin aponta para um servidor da
    # Sankhya ($RepoSearchFilters).
    param(
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
        'AppData', 'node_modules', '.git', '.vs', '.idea', 'bin', 'obj', 'target', 'build',
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
                $remote = Get-RepoOrigin $path
                $key = ConvertTo-UrlKey $remote
                if ($remote -and ($RepoSearchFilters | Where-Object { $key.StartsWith($_) })) {
                    $found.Add([pscustomobject]@{
                        Name   = Split-Path $path -Leaf
                        Path   = $path
                        Remote = $remote
                    })
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

# ------------------------------- VPN (FortiClient) --------------------------

function Open-FortiClientWindow {
    # Abre a janela do FortiClient clicando no icone FIXADO NA BARRA DE TAREFAS
    # (achado via UI Automation, procurando o botao cujo nome contem "FortiClient").
    # Lancar o .exe direto (Start-Process) NAO funciona de forma confiavel quando
    # ja existe uma instancia rodando so na bandeja - so relata pro processo
    # existente e sai, sem garantir que a janela apareca (testado e confirmado).
    # O clique no icone fixado da barra de tarefas, por outro lado, e confiavel.
    # Pre-requisito: o FortiClient precisa estar fixado na barra de tarefas
    # (clique direito no icone -> "Fixar na barra de tarefas", 1x so, manual).
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

function Show-FortiClientWindow {
    # Abre (ou traz para frente) a janela do FortiClient quando a VPN esta caida,
    # sem clicar em nada - usado quando a VPN automatica esta desligada.
    param()

    $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "FortiClient*" } | Select-Object -First 1
    if (-not $proc) {
        return (Open-FortiClientWindow)
    }

    try {
        if (-not ("SankhyaFcWin32" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SankhyaFcWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
        }
        [SankhyaFcWin32]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null
        [SankhyaFcWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    } catch {}
    return $true
}

function Add-SankhyaVpnWin32Type {
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
}

function Select-SankhyaGoogleAccount {
    # Se o SSO abrir a tela "Escolha uma conta" do Google (quando o navegador
    # tem mais de uma conta logada), acha e clica na conta do dominio sankhya
    # sozinho. Usa UI Automation pra achar o elemento pelo TEXTO (email visivel),
    # nao por coordenada de pixel - por isso funciona em qualquer monitor onde a
    # janela abrir. Chamada nao bloqueante: se a tela nao apareceu ainda, so
    # retorna false e quem chamou tenta de novo depois.
    param([string]$AccountDomain = "sankhya.com.br")

    $browserProc = Get-Process | Where-Object {
        ($_.ProcessName -eq "chrome" -or $_.ProcessName -eq "msedge") -and
        $_.MainWindowTitle -like "*Contas do Google*"
    } | Select-Object -First 1
    if (-not $browserProc) { return $false }

    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        Add-SankhyaVpnWin32Type

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
    # Clica sozinho no botao "Conectar" da janela do FortiClient. As coordenadas
    # do botao Home e do botao Conectar sao guardadas como PROPORCAO da AREA DE
    # CONTEUDO da janela (GetClientRect - exclui barra de titulo/bordas do
    # Windows, que variam de tamanho entre maquinas por DPI/tema e por isso nao
    # sao uma referencia confiavel). Calibrado numa janela cuja area de conteudo
    # mede 877x675, onde Home fica em (675,74) e o botao Conectar vai de ~452 a
    # ~474 de altura. Mirar o CENTRO (462) do botao deu miss em outras maquinas
    # onde o popup renderiza um pouco maior (o botao real fica mais embaixo do
    # que o calculado). Mover pra perto da borda (470) ajudou mas ainda errou por
    # cima em algumas maquinas - o alvo em Y ficou ainda mais colado na borda de
    # baixo (474, no proprio limite medido) pra dar o maximo de folga pra quando
    # o botao aparece mais baixo.
    param(
        [Parameter(Mandatory)] [string]$GitHostName,
        [double]$HomeXRatio = (675.0 / 877.0),
        [double]$HomeYRatio = (74.0 / 675.0),
        [double]$ConnectXRatio = (429.0 / 877.0),
        [double]$ConnectYRatio = (474.0 / 675.0),
        [int]$WaitForWindowSeconds = 10,
        [int]$WaitForConnectSeconds = 25,
        [int]$MaxAttempts = 6
    )

    Add-SankhyaVpnWin32Type

    # Todo o processo (achar/abrir a janela, clicar em Conectar, esperar e
    # selecionar a conta do Google se aparecer) fica numa "tentativa" que pode
    # ser repetida. Se a 1a tentativa completa falhar (ex: demorou mais que o
    # esperado, ou a autenticacao nao fechou a tempo), tenta tudo de novo do
    # zero ate MaxAttempts vezes, em vez de desistir na primeira. Na pratica
    # 2-3 tentativas costumam bastar, mas subiu pra 6 (~3min no pior caso) pra
    # cobrir dias em que o FortiClient/SSO demora mais - nao e ilimitado de
    # proposito, pra nao travar pra sempre numa maquina onde a VPN realmente
    # esta fora do ar.
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 3 }

        $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "FortiClient*" } | Select-Object -First 1
        if (-not $proc) {
            if (Open-FortiClientWindow -WaitForWindowSeconds $WaitForWindowSeconds) {
                $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "FortiClient*" } | Select-Object -First 1
            }
        }
        if (-not $proc) { continue }

        try {
            [SankhyaVpnWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
        } catch { continue }
        Start-Sleep -Milliseconds 600

        $clientRect = New-Object SankhyaVpnWin32+RECT
        [SankhyaVpnWin32]::GetClientRect($proc.MainWindowHandle, [ref]$clientRect) | Out-Null
        $w = $clientRect.Right - $clientRect.Left
        $h = $clientRect.Bottom - $clientRect.Top

        if ($w -lt 200 -or $h -lt 200) { continue }

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

        # Trava mouse/teclado do usuario so durante os cliques em si (mouse real
        # mexendo ao mesmo tempo desvia o cursor sintetico e o clique erra o
        # botao). O try/finally garante que destrava mesmo se algo falhar no
        # meio - nunca fica travado.
        $alreadyConnected = $false
        try {
            [SankhyaVpnWin32]::BlockInput($true) | Out-Null

            Send-SankhyaClick $HomeXRatio $HomeYRatio
            Start-Sleep -Milliseconds 400

            if (Test-GitHostReachable -GitHostName $GitHostName) {
                $alreadyConnected = $true
            } else {
                Send-SankhyaClick $ConnectXRatio $ConnectYRatio
            }
        } finally {
            [SankhyaVpnWin32]::BlockInput($false) | Out-Null
        }

        if ($alreadyConnected) { return $true }

        # Dentro de UMA tentativa, so reclica em "Conectar" uma vez, e so se
        # nada tiver acontecido ainda - nem a tela de login do Google chegou a
        # abrir (sinal de que o clique realmente nao pegou). Uma vez que o
        # login do Google apareceu, nao reclica mais NESSA tentativa - reclicar
        # as cegas enquanto o login esta em andamento corre o risco de acertar
        # "Desconectar" sem querer. Se a tentativa inteira falhar mesmo assim,
        # a proxima tentativa do loop de fora recomeca do zero.
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
        # essa tentativa falhou - se sobrar tentativa no loop de fora, comeca de novo
    }
    return $false
}

# --------------------------------- atualizacao ------------------------------

function Invoke-SankhyaUpdate {
    param([switch]$Unattended)

    # Na tarefa agendada ninguem esta olhando a tela: o git nunca pode ficar
    # parado esperando login (ex: primeiro acesso ao GitHub). Sem credencial
    # salva, falha na hora e o log pede pra rodar o atalho manual 1x.
    if ($Unattended) {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
    }

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $logFile = Join-Path $LogDir ("update-{0}.log" -f (Get-Date -Format "yyyyMM"))

    $result = [ordered]@{
        VpnDown            = $false
        VpnAutoConnected   = $false
        Cloned             = @()
        RemoteSwitched     = @()
        Updated            = @()
        DiscardedLocal     = @()
        StashedLocal       = @()
        Unreachable        = @()
        SkippedNoUpstream  = @()
        Errors             = @()
        LogFile            = $logFile
    }

    if (@($Config.Repos).Count -eq 0) {
        $result.Errors += "Nenhum modulo configurado. Abra o Sankhya-Repo-Updater.bat (2 cliques), marque os modulos e clique em 'Salvar e instalar'."
    }

    # Resultado do teste de conexao por servidor, feito 1x so por execucao.
    # Servidor de VPN fora do ar: tenta conectar o FortiClient (1x so).
    $hostState = @{}
    $resolveHost = {
        param([string]$GitHostName)
        if (-not $GitHostName) { return $true }   # caminho local / URL desconhecida: deixa o git decidir
        if ($hostState.ContainsKey($GitHostName)) { return $hostState[$GitHostName] }

        $ok = Test-GitHostReachable -GitHostName $GitHostName
        if (-not $ok -and ($Config.VpnHosts -contains $GitHostName)) {
            Write-Host "  VPN parece desconectada ($GitHostName)..." -ForegroundColor Yellow
            if ($Config.VpnAutoConnect) {
                Write-Host "  tentando conectar o FortiClient sozinho..." -ForegroundColor Yellow
                $result.VpnAutoConnected = [bool](Connect-SankhyaVpn -GitHostName $GitHostName)
            } else {
                Show-FortiClientWindow | Out-Null
            }
            $ok = Test-GitHostReachable -GitHostName $GitHostName
            if (-not $ok) { $result.VpnDown = $true }
        }
        $hostState[$GitHostName] = $ok
        return $ok
    }

    foreach ($repo in @(Get-RepoList)) {
        $name = $repo.Name
        $path = $repo.Path
        Write-Host "- $name" -ForegroundColor Cyan

        try {
            # ---- pasta ainda nao existe: clona ----
            if (-not (Test-Path (Join-Path $path ".git"))) {
                if ((Test-Path $path) -and (Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1)) {
                    $result.Errors += "${name}: a pasta $path existe, nao esta vazia e nao e um repositorio git (nao clonei por cima)"
                    continue
                }
                if (-not $repo.Url) {
                    $result.Errors += "${name}: pasta nao encontrada ($path) e sem Url configurada para clonar"
                    continue
                }
                $gitHostName = Get-UrlHost $repo.Url
                if (-not (& $resolveHost $gitHostName)) {
                    $result.Unreachable += "$name ($gitHostName)"
                    continue
                }

                Write-Host "  clonando de $($repo.Url) (pode demorar)..."
                $cloneArgs = @('clone', '--config', 'core.longpaths=true')
                if ($repo.Branch) { $cloneArgs += @('--branch', $repo.Branch) }
                $cloneArgs += @($repo.Url, $path)
                $clone = Invoke-Git $null $cloneArgs
                if ($clone.Ok) {
                    $branch = (Invoke-Git $path @('rev-parse', '--abbrev-ref', 'HEAD')).Text
                    $result.Cloned += "${name}: clonado de $($repo.Url) (branch $branch)"
                } else {
                    $result.Errors += "${name}: falha ao clonar $($repo.Url) - $(Get-ShortGitError $clone.Text)"
                }
                continue
            }

            # ---- repositorio existente ----
            $originUrl = (Invoke-Git $path @('remote', 'get-url', 'origin')).Text
            $targetUrl = if ($repo.Url) { $repo.Url } else { $originUrl }
            $gitHostName = Get-UrlHost $targetUrl
            if (-not (& $resolveHost $gitHostName)) {
                $result.Unreachable += "$name ($gitHostName)"
                continue
            }

            # origin aponta para outro servidor (ex: migrado do GitLab para o GitHub):
            # so troca depois de confirmar que a URL nova responde, pra nunca deixar
            # o repositorio apontando para um lugar inacessivel.
            if ($repo.Url -and ((ConvertTo-UrlKey $originUrl) -ne (ConvertTo-UrlKey $repo.Url))) {
                Write-Host "  origin atual: $originUrl"
                Write-Host "  conferindo acesso a $($repo.Url)..."
                $probe = Invoke-Git $null @('ls-remote', '--heads', $repo.Url)
                if (-not $probe.Ok) {
                    $hint = if ($Unattended) { " (rode o atalho manual 1x para fazer login)" } else { "" }
                    $result.Errors += "${name}: sem acesso a $($repo.Url), origin mantido em $originUrl - $(Get-ShortGitError $probe.Text)$hint"
                    continue
                }
                $setUrl = if ($originUrl) {
                    Invoke-Git $path @('remote', 'set-url', 'origin', $repo.Url)
                } else {
                    Invoke-Git $path @('remote', 'add', 'origin', $repo.Url)
                }
                if (-not $setUrl.Ok) {
                    $result.Errors += "${name}: falha ao trocar o origin - $(Get-ShortGitError $setUrl.Text)"
                    continue
                }
                $result.RemoteSwitched += "${name}: $originUrl -> $($repo.Url)"
            }

            # Outro git rodando no mesmo repositorio ao mesmo tempo (ex: auto-fetch do
            # VS Code) faz o fetch falhar com "cannot lock ref ... .lock: File exists".
            # E passageiro: espera e tenta de novo.
            #
            # Outro caso com a mesma mensagem: o remoto antigo tinha dois branches que
            # so diferem em maiusculas/minusculas (ex: hotfix-rc-KB-1 e hotfix-rc-kb-1).
            # No Windows os dois viram o mesmo arquivo .lock e o --prune colide consigo
            # mesmo, sempre. Esses refs remotos sao apagados um a um antes de tentar de novo.
            $caseFixed = $false
            for ($try = 1; $try -le 4; $try++) {
                $fetch = Invoke-Git $path @('fetch', 'origin', '--prune', '--quiet')
                if ($fetch.Ok -or $fetch.Text -notmatch '\.lock') { break }
                if (-not $caseFixed -and $fetch.Text -match 'could not delete references') {
                    $caseFixed = $true
                    $refs = @((Invoke-Git $path @('for-each-ref', '--format=%(refname)', 'refs/remotes/origin')).Text -split "`n" | Where-Object { $_ })
                    $dupes = @($refs | Group-Object { $_.ToLower() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group })
                    if ($dupes.Count -gt 0) {
                        Write-Host "  removendo $($dupes.Count) refs remotos que so diferem em maiusculas/minusculas..." -ForegroundColor Yellow
                        foreach ($ref in $dupes) { Invoke-Git $path @('update-ref', '-d', $ref) | Out-Null }
                        continue
                    }
                }
                Write-Host "  repositorio ocupado por outro processo git, tentando de novo..." -ForegroundColor Yellow
                Start-Sleep -Seconds (5 * $try)
            }
            if (-not $fetch.Ok) {
                $hint = if ($Unattended) { " (VPN/credenciais - se for login, rode o atalho manual 1x)" } else { "" }
                $result.Errors += "${name}: falha no 'git fetch' - $(Get-ShortGitError $fetch.Text)$hint"
                continue
            }

            $upstream = Invoke-Git $path @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            if (-not $upstream.Ok -or -not $upstream.Text) {
                $branch = (Invoke-Git $path @('rev-parse', '--abbrev-ref', 'HEAD')).Text
                $result.SkippedNoUpstream += "$name (branch local '$branch' sem branch correspondente no origin)"
                continue
            }

            $behind = Invoke-Git $path @('rev-list', '--count', "HEAD..$($upstream.Text)")
            if (-not $behind.Ok -or [int]$behind.Text -eq 0) { continue }

            # So mexe nas alteracoes locais quando realmente ha algo pra puxar.
            $status = Invoke-Git $path @('status', '--porcelain')
            if (-not $status.Ok) {
                $result.Errors += "${name}: falha ao rodar 'git status'"
                continue
            }
            if ($status.Text) {
                $changedFiles = (($status.Text -split "`n") | ForEach-Object { $_.Trim() }) -join "; "

                if ($Config.DiscardMode -eq "hard") {
                    $reset = Invoke-Git $path @('reset', '--hard', '--quiet')
                    $clean = Invoke-Git $path @('clean', '-fd', '--quiet')
                    if (-not ($reset.Ok -and $clean.Ok)) {
                        $result.Errors += "${name}: falha ao descartar alteracoes locais ('git reset --hard' / 'git clean -fd')"
                        continue
                    }
                    $result.DiscardedLocal += "${name}: descartado -> $changedFiles"
                } else {
                    $stash = Invoke-Git $path @('stash', 'push', '-u', '-m', "auto-update $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '--quiet')
                    if (-not $stash.Ok) {
                        $result.Errors += "${name}: falha ao guardar alteracoes locais ('git stash')"
                        continue
                    }
                    $result.StashedLocal += "${name}: guardado em stash -> $changedFiles"
                }
            }

            $beforeDescribe = (Invoke-Git $path @('describe', '--tags', '--always')).Text
            Write-Host "  atualizando ($($behind.Text) commit(s) novos)..."
            for ($try = 1; $try -le 4; $try++) {
                $pull = Invoke-Git $path @('pull', '--ff-only', '--quiet')
                if ($pull.Ok -or $pull.Text -notmatch '\.lock') { break }
                Write-Host "  repositorio ocupado por outro processo git, tentando de novo..." -ForegroundColor Yellow
                Start-Sleep -Seconds (5 * $try)
            }
            if ($pull.Ok) {
                $afterDescribe = (Invoke-Git $path @('describe', '--tags', '--always')).Text
                $result.Updated += "${name}: $beforeDescribe -> $afterDescribe"
            } else {
                $result.Errors += "${name}: 'git pull --ff-only' falhou (provavel divergencia, precisa de acao manual) - $(Get-ShortGitError $pull.Text)"
            }
        } catch {
            $result.Errors += "${name}: erro inesperado - $($_.Exception.Message)"
        }
    }

    $logLines = @("=== Verificacao em $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===") + (Get-ResultLines $result) + @("")
    Add-Content -Path $logFile -Value ($logLines -join "`r`n") -Encoding utf8

    return $result
}

function Get-ResultLines {
    param($Result)

    $lines = @()
    if ($Result.VpnAutoConnected) {
        $lines += "VPN conectada automaticamente (estava desconectada)."
    }
    if ($Result.VpnDown) {
        $lines += "VPN desconectada: os modulos do GitLab nao foram verificados. Conecte a VPN e rode o atalho manual novamente."
    }

    $sections = [ordered]@{
        "Clonados:"                                                            = $Result.Cloned
        "Origin trocado para o novo servidor:"                                 = $Result.RemoteSwitched
        "Atualizados:"                                                         = $Result.Updated
        "ATENCAO - alteracoes locais descartadas (reset --hard + clean -fd):"  = $Result.DiscardedLocal
        "Alteracoes locais guardadas em stash (git stash pop para recuperar):" = $Result.StashedLocal
        "Nao verificados (servidor inacessivel):"                              = $Result.Unreachable
        "Pulados (sem branch remoto associado):"                               = $Result.SkippedNoUpstream
        "Erros:"                                                               = $Result.Errors
    }
    foreach ($title in $sections.Keys) {
        $items = @($sections[$title])
        if ($items.Count -gt 0) {
            $lines += $title
            $lines += ($items | ForEach-Object { "  - $_" })
        }
    }

    if ($lines.Count -eq 0) { $lines += "Tudo em dia, nenhuma novidade." }
    return $lines
}

function Test-ResultHasNews {
    param($Result)
    return ($Result.VpnDown -or $Result.VpnAutoConnected -or
        @($Result.Cloned).Count -gt 0 -or @($Result.RemoteSwitched).Count -gt 0 -or
        @($Result.Updated).Count -gt 0 -or @($Result.DiscardedLocal).Count -gt 0 -or
        @($Result.StashedLocal).Count -gt 0 -or @($Result.Unreachable).Count -gt 0 -or
        @($Result.Errors).Count -gt 0)
}

function Test-ResultIsWarning {
    param($Result)
    return ($Result.VpnDown -or @($Result.Errors).Count -gt 0 -or
        @($Result.DiscardedLocal).Count -gt 0 -or @($Result.Unreachable).Count -gt 0)
}

# ------------------------------------ modos ---------------------------------

function Invoke-Scheduled {
    $result = Invoke-SankhyaUpdate -Unattended
    if (-not (Test-ResultHasNews $result)) { return }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true

        $title = if ($result.VpnDown) { "Sankhya - VPN desconectada" } else { "Sankhya - modulos" }
        $msgBody = (Get-ResultLines $result) -join "`n"
        if ($msgBody.Length -gt 250) { $msgBody = $msgBody.Substring(0, 250) + "..." }
        $icon = if (Test-ResultIsWarning $result) { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }

        $notify.ShowBalloonTip(15000, $title, $msgBody, $icon)
        Start-Sleep -Seconds 16
        $notify.Dispose()
    } catch {
        Add-Content -Path $result.LogFile -Value "  (falha ao exibir notificacao: $($_.Exception.Message))" -Encoding utf8
    }
}

function Invoke-Manual {
    Write-Host "Verificando modulos, aguarde..." -ForegroundColor Cyan
    Write-Host ""
    $result = Invoke-SankhyaUpdate
    $lines = Get-ResultLines $result

    Write-Host ""
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Host "Log: $($result.LogFile)" -ForegroundColor DarkGray

    Add-Type -AssemblyName System.Windows.Forms
    $icon = if (Test-ResultIsWarning $result) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [System.Windows.Forms.MessageBox]::Show(
        ($lines -join "`n"),
        "Resultado da atualizacao",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null
}

function Get-RepoSituation {
    param([string]$Path, [string]$Origin, [string]$Url)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        if ((Test-Path -LiteralPath $Path) -and (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) {
            return 'ERRO: pasta existe e nao e repositorio git'
        }
        return 'sera clonado'
    }
    if ($Url -and ((ConvertTo-UrlKey $Origin) -ne (ConvertTo-UrlKey $Url))) {
        return "origin sera trocado para o $(Get-ServerLabel $Url)"
    }
    return 'ok'
}

function Show-Status {
    # So leitura: mostra o que a proxima atualizacao faria com cada modulo.
    if (-not $Config.Configured) {
        Write-Host "Ainda nao configurado ($ConfigPath nao existe). Abra o .bat com 2 cliques." -ForegroundColor Yellow
        return
    }
    $hostState = @{}
    foreach ($repo in @(Get-RepoList)) {
        $originUrl = Get-RepoOrigin $repo.Path
        $targetUrl = if ($repo.Url) { $repo.Url } else { $originUrl }
        $gitHostName = Get-UrlHost $targetUrl
        if ($gitHostName -and -not $hostState.ContainsKey($gitHostName)) {
            $hostState[$gitHostName] = Test-GitHostReachable -GitHostName $gitHostName
        }
        $action = Get-RepoSituation $repo.Path $originUrl $repo.Url
        $reach = if (-not $gitHostName) { "?" } elseif ($hostState[$gitHostName]) { "acessivel" } else { "INACESSIVEL" }

        Write-Host ("{0,-24} {1}" -f $repo.Name, $action) -ForegroundColor $(if ($action -eq 'ok') { 'Green' } elseif ($action -like 'ERRO*') { 'Red' } else { 'Yellow' })
        Write-Host "    pasta : $($repo.Path)"
        if ($originUrl) { Write-Host "    origin: $originUrl" }
        if ($repo.Url -and $action -ne 'ok') { Write-Host "    novo  : $($repo.Url)" }
        Write-Host "    host  : $gitHostName ($reach)"
    }
    Write-Host ""
    Write-Host (Get-InstallStatusText)
}

function Get-InstallStatusText {
    $task = Get-ScheduledTask -TaskName $Config.TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return "Nao instalado (sem verificacao diaria)." }
    $taskCmd = "$($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
    if ($taskCmd -notlike "*$SnkSelf*") {
        return "Ha uma verificacao diaria de OUTRA versao instalada - clique em 'Salvar e instalar' para trocar por esta."
    }
    $at = ''
    try { $at = ([datetime]$task.Triggers[0].StartBoundary).ToString('HH:mm') } catch {}
    return "Instalado: verificacao diaria as $at."
}

function Install-Updater {
    foreach ($repo in @(Get-RepoList)) {
        if (Test-Path (Join-Path $repo.Path ".git")) {
            Invoke-Git $repo.Path @('config', 'core.longpaths', 'true') | Out-Null
        }
    }

    # A tarefa chama o PowerShell direto (janela oculta) lendo este arquivo,
    # sem passar pelo cmd - assim nao fica janela de console aberta.
    $selfEsc = $SnkSelf -replace "'", "''"
    $psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"`$SnkMode='/agendado'; `$SnkSelf='$selfEsc'; Invoke-Expression ([IO.File]::ReadAllText(`$SnkSelf))`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
    $trigger = New-ScheduledTaskTrigger -Daily -At $Config.ScheduleTime
    # StartWhenAvailable: se o PC estava desligado/bloqueado no horario, roda assim que possivel.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $Config.TaskName -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "Tarefa agendada '$($Config.TaskName)' criada para rodar 1x por dia as $($Config.ScheduleTime)." -ForegroundColor Green

    $WshShell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktop ("{0}.lnk" -f $Config.ShortcutName)
    $shortcut = $WshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $SnkSelf
    $shortcut.Arguments = "/agora"
    $shortcut.WorkingDirectory = Split-Path $SnkSelf
    $shortcut.IconLocation = "shell32.dll,238"
    $shortcut.Description = "Verifica e atualiza os modulos configurados (git pull) e mostra o resultado"
    $shortcut.Save()
    Write-Host "Atalho criado na area de trabalho: $shortcutPath" -ForegroundColor Green
    return $shortcutPath
}

function Uninstall-Updater {
    Unregister-ScheduledTask -TaskName $Config.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Tarefa agendada '$($Config.TaskName)' removida (se existia)." -ForegroundColor Cyan

    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) ("{0}.lnk" -f $Config.ShortcutName)
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "Atalho removido: $shortcutPath" -ForegroundColor Cyan
    }
}

# ------------------------------------ janela --------------------------------

function Get-RepoCandidates {
    # Junta, sem repetir: o que ja esta salvo/marcado ($Current), o que foi
    # encontrado no disco e os modulos conhecidos ($KnownRepos) ainda ausentes.
    param(
        [string]$ReposRoot,
        [string[]]$ScanRoots,
        [int]$MaxDepth = 3,
        [object[]]$Current,
        [switch]$CheckFound,
        [switch]$AllDrives
    )

    $rows = [ordered]@{}
    foreach ($c in @($Current)) {
        if (-not $c.Path) { continue }
        $rows[$c.Path.ToLower()] = [pscustomobject]@{
            Checked = [bool]$c.Checked; Name = (Split-Path $c.Path -Leaf); Path = $c.Path; Url = $c.Url; Origin = (Get-RepoOrigin $c.Path)
        }
    }

    $found = if ($AllDrives) {
        Find-SankhyaRepos -MaxDepth $MaxDepth
    } elseif (@($ScanRoots | Where-Object { $_ }).Count -gt 0) {
        Find-SankhyaRepos -SearchRoots $ScanRoots -MaxDepth $MaxDepth
    } else { @() }
    foreach ($f in @($found)) {
        $k = $f.Path.ToLower()
        if ($rows.Contains($k)) { continue }
        $url = if ($KnownRepos.Contains($f.Name)) { $KnownRepos[$f.Name] } else { $f.Remote }
        $rows[$k] = [pscustomobject]@{
            Checked = [bool]$CheckFound; Name = $f.Name; Path = $f.Path; Url = $url; Origin = $f.Remote
        }
    }

    $names = @($rows.Values | ForEach-Object { $_.Name.ToLower() })
    foreach ($name in $KnownRepos.Keys) {
        if ($names -contains $name.ToLower()) { continue }
        $path = Join-Path $ReposRoot $name
        $rows[$path.ToLower()] = [pscustomobject]@{
            Checked = $false; Name = $name; Path = $path; Url = $KnownRepos[$name]; Origin = (Get-RepoOrigin $path)
        }
    }

    return @($rows.Values)
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Esconde a janela preta do cmd enquanto a janela de configuracao esta aberta.
    try {
        if (-not ("SankhyaConsoleWin" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SankhyaConsoleWin {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
        }
        [SankhyaConsoleWin]::ShowWindow([SankhyaConsoleWin]::GetConsoleWindow(), 0) | Out-Null
    } catch {}

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Sankhya Repo Updater'
    $form.ClientSize = New-Object System.Drawing.Size(900, 600)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 520)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Icon = [System.Drawing.SystemIcons]::Application

    $ttl = New-Object System.Windows.Forms.Label
    $ttl.Text = 'Marque os modulos que devem ser mantidos atualizados. Os que ainda nao existem na pasta serao clonados.'
    $ttl.Location = New-Object System.Drawing.Point(12, 12)
    $ttl.AutoSize = $true
    $form.Controls.Add($ttl)

    $lblRoot = New-Object System.Windows.Forms.Label
    $lblRoot.Text = 'Pasta dos projetos:'
    $lblRoot.Location = New-Object System.Drawing.Point(12, 43)
    $lblRoot.AutoSize = $true
    $form.Controls.Add($lblRoot)

    $txtRoot = New-Object System.Windows.Forms.TextBox
    $txtRoot.Location = New-Object System.Drawing.Point(130, 40)
    $txtRoot.Size = New-Object System.Drawing.Size(560, 23)
    $txtRoot.Anchor = 'Top, Left, Right'
    $txtRoot.Text = $Config.ReposRoot
    $form.Controls.Add($txtRoot)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Escolher...'
    $btnBrowse.Location = New-Object System.Drawing.Point(698, 39)
    $btnBrowse.Size = New-Object System.Drawing.Size(90, 25)
    $btnBrowse.Anchor = 'Top, Right'
    $form.Controls.Add($btnBrowse)

    $btnRescan = New-Object System.Windows.Forms.Button
    $btnRescan.Text = 'Procurar'
    $btnRescan.Location = New-Object System.Drawing.Point(796, 39)
    $btnRescan.Size = New-Object System.Drawing.Size(92, 25)
    $btnRescan.Anchor = 'Top, Right'
    $form.Controls.Add($btnRescan)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 74)
    $grid.Size = New-Object System.Drawing.Size(876, 300)
    $grid.Anchor = 'Top, Bottom, Left, Right'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colChk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colChk.HeaderText = 'Atualizar'; $colChk.Width = 65
    [void]$grid.Columns.Add($colChk)
    foreach ($c in @(
            @{ H = 'Modulo'; W = 170 }, @{ H = 'Servidor'; W = 70 }, @{ H = 'Situacao'; W = 210 },
            @{ H = 'Pasta'; W = 200 }, @{ H = 'Url'; W = 10 })) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $c.H; $col.Width = $c.W; $col.ReadOnly = $true
        [void]$grid.Columns.Add($col)
    }
    $grid.Columns[4].AutoSizeMode = 'Fill'
    $grid.Columns[5].Visible = $false
    $form.Controls.Add($grid)

    $btnAddUrl = New-Object System.Windows.Forms.Button
    $btnAddUrl.Text = 'Adicionar modulo por URL...'
    $btnAddUrl.Location = New-Object System.Drawing.Point(12, 382)
    $btnAddUrl.Size = New-Object System.Drawing.Size(190, 27)
    $btnAddUrl.Anchor = 'Bottom, Left'
    $form.Controls.Add($btnAddUrl)

    $btnScanAll = New-Object System.Windows.Forms.Button
    $btnScanAll.Text = 'Procurar no computador todo'
    $btnScanAll.Location = New-Object System.Drawing.Point(210, 382)
    $btnScanAll.Size = New-Object System.Drawing.Size(200, 27)
    $btnScanAll.Anchor = 'Bottom, Left'
    $form.Controls.Add($btnScanAll)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Opcoes'
    $grp.Location = New-Object System.Drawing.Point(12, 418)
    $grp.Size = New-Object System.Drawing.Size(876, 118)
    $grp.Anchor = 'Bottom, Left, Right'
    $form.Controls.Add($grp)

    $chkVpn = New-Object System.Windows.Forms.CheckBox
    $chkVpn.Text = 'Conectar a VPN (FortiClient) automaticamente quando estiver desconectada  (o FortiClient precisa estar fixado na barra de tarefas)'
    $chkVpn.Location = New-Object System.Drawing.Point(14, 24)
    $chkVpn.AutoSize = $true
    $chkVpn.Checked = [bool]$Config.VpnAutoConnect
    $grp.Controls.Add($chkVpn)

    $lblTime = New-Object System.Windows.Forms.Label
    $lblTime.Text = 'Verificar todo dia as:'
    $lblTime.Location = New-Object System.Drawing.Point(14, 57)
    $lblTime.AutoSize = $true
    $grp.Controls.Add($lblTime)

    $dtTime = New-Object System.Windows.Forms.DateTimePicker
    $dtTime.Format = 'Custom'
    $dtTime.CustomFormat = 'HH:mm'
    $dtTime.ShowUpDown = $true
    $dtTime.Location = New-Object System.Drawing.Point(150, 54)
    $dtTime.Size = New-Object System.Drawing.Size(70, 23)
    try { $dtTime.Value = [datetime]::ParseExact($Config.ScheduleTime, 'HH:mm', $null) } catch { $dtTime.Value = [datetime]::Today.AddHours(11) }
    $grp.Controls.Add($dtTime)

    $lblDiscard = New-Object System.Windows.Forms.Label
    $lblDiscard.Text = 'Alteracoes locais nao commitadas:'
    $lblDiscard.Location = New-Object System.Drawing.Point(14, 89)
    $lblDiscard.AutoSize = $true
    $grp.Controls.Add($lblDiscard)

    $cmbDiscard = New-Object System.Windows.Forms.ComboBox
    $cmbDiscard.DropDownStyle = 'DropDownList'
    $cmbDiscard.Location = New-Object System.Drawing.Point(220, 86)
    $cmbDiscard.Size = New-Object System.Drawing.Size(420, 23)
    [void]$cmbDiscard.Items.Add('Guardar em stash antes de atualizar (recomendado)')
    [void]$cmbDiscard.Items.Add('Descartar (reset --hard + clean) - APAGA sem volta')
    $cmbDiscard.SelectedIndex = $(if ($Config.DiscardMode -eq 'hard') { 1 } else { 0 })
    $grp.Controls.Add($cmbDiscard)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(12, 556)
    $lblStatus.Size = New-Object System.Drawing.Size(330, 34)
    $lblStatus.Anchor = 'Bottom, Left'
    $form.Controls.Add($lblStatus)

    $btnLogs = New-Object System.Windows.Forms.Button
    $btnLogs.Text = 'Logs'
    $btnLogs.Location = New-Object System.Drawing.Point(350, 552)
    $btnLogs.Size = New-Object System.Drawing.Size(70, 32)
    $btnLogs.Anchor = 'Bottom, Right'
    $form.Controls.Add($btnLogs)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text = 'Desinstalar'
    $btnUninstall.Location = New-Object System.Drawing.Point(428, 552)
    $btnUninstall.Size = New-Object System.Drawing.Size(95, 32)
    $btnUninstall.Anchor = 'Bottom, Right'
    $form.Controls.Add($btnUninstall)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = 'Atualizar agora'
    $btnRun.Location = New-Object System.Drawing.Point(531, 552)
    $btnRun.Size = New-Object System.Drawing.Size(120, 32)
    $btnRun.Anchor = 'Bottom, Right'
    $form.Controls.Add($btnRun)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Salvar e instalar'
    $btnSave.Location = New-Object System.Drawing.Point(659, 552)
    $btnSave.Size = New-Object System.Drawing.Size(229, 32)
    $btnSave.Anchor = 'Bottom, Right'
    $btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnSave)
    $form.AcceptButton = $btnSave

    # ---- comportamento ----

    $fillGrid = {
        param([object[]]$Candidates)
        $grid.Rows.Clear()
        foreach ($c in @($Candidates)) {
            $situation = Get-RepoSituation $c.Path $c.Origin $c.Url
            $i = $grid.Rows.Add([bool]$c.Checked, $c.Name, (Get-ServerLabel $c.Url), $situation, $c.Path, $c.Url)
            $color = if ($situation -eq 'ok') { [System.Drawing.Color]::ForestGreen }
                     elseif ($situation -like 'ERRO*') { [System.Drawing.Color]::Firebrick }
                     elseif ($situation -like 'origin*') { [System.Drawing.Color]::DarkOrange }
                     else { [System.Drawing.Color]::RoyalBlue }
            $grid.Rows[$i].Cells[3].Style.ForeColor = $color
        }
    }

    $getGridRows = {
        [void]$grid.EndEdit()
        foreach ($r in $grid.Rows) {
            [pscustomobject]@{ Checked = [bool]$r.Cells[0].Value; Path = [string]$r.Cells[4].Value; Url = [string]$r.Cells[5].Value }
        }
    }

    $scan = {
        param([string[]]$ScanRoots, [int]$MaxDepth, [bool]$CheckFound, [object[]]$Current, [bool]$AllDrives = $false)
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = if ($AllDrives) { 'Procurando em todos os discos (pode levar 1-2 minutos)...' } else { 'Procurando modulos...' }
        $form.Refresh()
        try {
            $cands = Get-RepoCandidates -ReposRoot $txtRoot.Text -ScanRoots $ScanRoots -MaxDepth $MaxDepth -Current $Current -CheckFound:$CheckFound -AllDrives:$AllDrives
            & $fillGrid $cands
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $lblStatus.Text = Get-InstallStatusText
        }
    }

    # Mantem na lista so o que esta marcado ou ja existe no disco (o resto e
    # remontado a partir da pasta atual e dos modulos conhecidos).
    $keepRows = { @(& $getGridRows | Where-Object { $_.Checked -or (Test-Path -LiteralPath (Join-Path $_.Path '.git')) }) }

    $saveConfig = {
        $rows = @(& $getGridRows | Where-Object { $_.Checked })
        if ($rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Marque pelo menos um modulo.', 'Sankhya Repo Updater', 'OK', 'Warning') | Out-Null
            return $false
        }
        Save-UpdaterConfig -ReposRoot $txtRoot.Text -Repos $rows -VpnAutoConnect $chkVpn.Checked `
            -ScheduleTime $dtTime.Value.ToString('HH:mm') -DiscardMode $(if ($cmbDiscard.SelectedIndex -eq 1) { 'hard' } else { 'stash' })
        return $true
    }

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pasta onde ficam (ou serao clonados) os modulos'
        if (Test-Path $txtRoot.Text) { $dlg.SelectedPath = $txtRoot.Text }
        if ($dlg.ShowDialog($form) -eq 'OK') {
            $txtRoot.Text = $dlg.SelectedPath
            & $scan @($txtRoot.Text) 3 $true (& $keepRows)
        }
    })

    $btnRescan.Add_Click({ & $scan @($txtRoot.Text) 3 $true (& $keepRows) })

    $btnScanAll.Add_Click({ & $scan @() 7 $true (& $keepRows) $true })

    $btnAddUrl.Add_Click({
        $url = [Microsoft.VisualBasic.Interaction]::InputBox(
            "URL do repositorio (ex: https://github.com/sankhya-tech/mgecom-module.git)",
            'Adicionar modulo', '')
        $url = $url.Trim()
        if (-not $url) { return }
        $name = (Split-Path ($url -replace '[\\/]+$', '') -Leaf) -replace '\.git$', ''
        $name = ($name -split ':')[-1]
        $path = Join-Path $txtRoot.Text $name
        $current = @(& $getGridRows)
        $existing = $current | Where-Object { $_.Path -eq $path -or (Split-Path $_.Path -Leaf) -eq $name } | Select-Object -First 1
        if ($existing) {
            $existing.Url = $url; $existing.Checked = $true
        } else {
            $current += [pscustomobject]@{ Checked = $true; Path = $path; Url = $url }
        }
        & $fillGrid (Get-RepoCandidates -ReposRoot $txtRoot.Text -ScanRoots @() -Current $current)
    })

    $btnSave.Add_Click({
        if (-not (& $saveConfig)) { return }
        try {
            $shortcutPath = Install-Updater
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Configuracao salva, mas a instalacao falhou:`n`n$($_.Exception.Message)", 'Sankhya Repo Updater', 'OK', 'Error') | Out-Null
            return
        }
        $lblStatus.Text = Get-InstallStatusText
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Pronto!`n`n" +
            "$(@($Config.Repos).Count) modulo(s) configurado(s).`n" +
            "Verificacao automatica todo dia as $($Config.ScheduleTime).`n" +
            "VPN automatica: $(if ($Config.VpnAutoConnect) { 'ligada' } else { 'desligada' }).`n" +
            "Atalho na area de trabalho: $($Config.ShortcutName)`n`n" +
            "Quer atualizar agora? (no primeiro acesso ao GitHub o login abre no navegador)",
            'Sankhya Repo Updater', 'YesNo', 'Information')
        if ($answer -eq 'Yes') { Start-Process -FilePath $SnkSelf -ArgumentList '/agora' }
    })

    $btnRun.Add_Click({
        if (-not (& $saveConfig)) { return }
        Start-Process -FilePath $SnkSelf -ArgumentList '/agora'
    })

    $btnUninstall.Add_Click({
        $ok = [System.Windows.Forms.MessageBox]::Show('Remover a verificacao diaria e o atalho da area de trabalho?', 'Sankhya Repo Updater', 'YesNo', 'Question')
        if ($ok -ne 'Yes') { return }
        Uninstall-Updater
        $lblStatus.Text = Get-InstallStatusText
    })

    $btnLogs.Add_Click({
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Start-Process explorer.exe $LogDir
    })

    $form.Add_Shown({
        $saved = @($Config.Repos | ForEach-Object {
            $p = if ([IO.Path]::IsPathRooted($_.Name)) { $_.Name } else { Join-Path $Config.ReposRoot $_.Name }
            [pscustomobject]@{ Checked = $true; Path = $p; Url = $_.Url }
        })
        # Primeira vez (sem config.json): ja deixa marcado tudo o que achou no disco.
        & $scan @($txtRoot.Text) 3 (-not $Config.Configured) $saved
    })

    [void]$form.ShowDialog()
}

# ------------------------------------ entrada -------------------------------

switch ($SnkMode.Trim().TrimStart('/', '-').ToLower()) {
    '' {
        try {
            Show-MainWindow
        } catch {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show("Erro inesperado:`n`n$($_.Exception.Message)", 'Sankhya Repo Updater', 'OK', 'Error') | Out-Null
        }
    }
    'agora'       { Invoke-Manual }
    'agendado'    { Invoke-Scheduled }
    'status'      { Show-Status }
    'instalar'    { Install-Updater | Out-Null }
    'desinstalar' { Uninstall-Updater }
    default {
        Write-Host "Opcao desconhecida: $SnkMode" -ForegroundColor Red
        Write-Host "Use: /agora | /agendado | /status | /instalar | /desinstalar  (ou sem nada para abrir a janela)"
        exit 1
    }
}

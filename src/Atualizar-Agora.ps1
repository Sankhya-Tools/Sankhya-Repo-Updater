param(
    [string]$PackageRoot
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

function Get-ConfiguredRepoPaths {
    param([Parameter(Mandatory)] $Config)
    if ($Config.PSObject.Properties.Name -contains 'repoPaths' -and $Config.repoPaths -and @($Config.repoPaths).Count -gt 0) {
        return @($Config.repoPaths)
    }
    if (-not $Config.reposRoot -or -not $Config.repoNames) { return @() }
    return @($Config.repoNames | ForEach-Object { Join-Path $Config.reposRoot $_ })
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

function Open-FortiClientWindow {
    # Abre a janela do FortiClient clicando no icone FIXADO NA BARRA DE TAREFAS
    # (achado via UI Automation, procurando o botao cujo nome contem "FortiClient").
    # Lancar o .exe direto (Start-Process) NAO funciona de forma confiavel quando
    # ja existe uma instancia rodando so na bandeja - so relata pro processo
    # existente e sai, sem garantir que a janela apareça (testado e confirmado).
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
    # sem clicar em nada - usado quando vpnAutoConnect esta desligado no config.json.
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
    # So roda se "vpnAutoConnect": true estiver no config.json (opt-in, desligado
    # por padrao no template). Clica sozinho no botao "Conectar" da janela do
    # FortiClient. As coordenadas do botao Home e do botao Conectar sao guardadas
    # como PROPORCAO da AREA DE CONTEUDO da janela (GetClientRect - exclui barra
    # de titulo/bordas do Windows, que variam de tamanho entre maquinas por
    # DPI/tema e por isso nao sao uma referencia confiavel). Calibrado numa
    # janela cuja area de conteudo mede 877x675, onde Home fica em (675,74) e o
    # botao Conectar vai de ~452 a ~474 de altura. Mirar o CENTRO (462) do botao
    # deu miss em outras maquinas onde o popup renderiza um pouco maior (o botao
    # real fica mais embaixo do que o calculado). Mover pra perto da borda (470)
    # ajudou mas ainda errou por cima em algumas maquinas - o alvo em Y ficou
    # ainda mais colado na borda de baixo (474, no proprio limite medido)
    # pra dar o maximo de folga pra quando o botao aparece mais baixo.
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

function Invoke-SankhyaUpdate {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$PackageRoot
    )

    # Avisos benignos do git no stderr (ex: aviso de conversao de LF/CRLF) nao podem
    # virar erro terminante aqui - o chamador roda com $ErrorActionPreference = "Stop",
    # e no Windows PowerShell 5.1 qualquer linha de stderr de um programa externo vira
    # um erro terminante nesse modo. As checagens de $LASTEXITCODE abaixo ja cobrem as
    # falhas reais de cada comando git.
    $ErrorActionPreference = 'Continue'

    $gitHostName = $Config.gitHost
    $repos = Get-ConfiguredRepoPaths -Config $Config
    $logDir = Join-Path $PackageRoot "logs"
    $discardMode = if ($Config.discardMode) { $Config.discardMode } else { "stash" }

    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logFile = Join-Path $logDir ("update-{0}.log" -f (Get-Date -Format "yyyyMM"))

    $result = [ordered]@{
        VpnDown            = $false
        VpnAutoConnected   = $false
        Updated            = @()
        DiscardedLocal     = @()
        StashedLocal       = @()
        SkippedNoUpstream  = @()
        Errors             = @()
        LogFile            = $logFile
    }

    if ($repos.Count -eq 0) {
        $result.Errors += "Nenhum repositorio configurado. Rode Instalar-Automatico.bat ou ajuste config.json."
        return $result
    }

    if (-not (Test-GitHostReachable -GitHostName $gitHostName)) {
        $autoConnectEnabled = ($Config.PSObject.Properties.Name -contains 'vpnAutoConnect') -and $Config.vpnAutoConnect
        if ($autoConnectEnabled) {
            $result.VpnAutoConnected = Connect-SankhyaVpn -GitHostName $gitHostName
        } else {
            Show-FortiClientWindow | Out-Null
        }
    }

    if (-not (Test-GitHostReachable -GitHostName $gitHostName)) {
        $result.VpnDown = $true
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $msg = if ($result.VpnAutoConnected -eq $false -and ($Config.PSObject.Properties.Name -contains 'vpnAutoConnect') -and $Config.vpnAutoConnect) {
            "VPN/rede indisponivel: tentei conectar sozinho (vpnAutoConnect) mas nao consegui alcancar $gitHostName."
        } else {
            "VPN/rede indisponivel: nao foi possivel alcancar $gitHostName. Abri o FortiClient pra facilitar."
        }
        $lines = @(
            "=== Verificacao em $timestamp ===",
            $msg,
            "Conecte a VPN manualmente e rode o atalho novamente.",
            ""
        )
        Add-Content -Path $logFile -Value ($lines -join "`r`n") -Encoding utf8
        return $result
    }

    foreach ($repo in $repos) {
        $name = Split-Path $repo -Leaf

        if (-not (Test-Path (Join-Path $repo ".git"))) {
            $result.Errors += "${name}: pasta nao encontrada ou nao e repositorio git ($repo)"
            continue
        }

        try {
            Push-Location $repo

            $status = git status --porcelain 2>$null
            if ($LASTEXITCODE -ne 0) {
                $result.Errors += "${name}: falha ao rodar 'git status'"
                Pop-Location
                continue
            }

            if ($status) {
                $changedFiles = ($status | ForEach-Object { $_.Trim() }) -join "; "

                if ($discardMode -eq "hard") {
                    git reset --hard --quiet 2>$null
                    $resetOk = ($LASTEXITCODE -eq 0)
                    git clean -fd --quiet 2>$null
                    $cleanOk = ($LASTEXITCODE -eq 0)

                    if (-not ($resetOk -and $cleanOk)) {
                        $result.Errors += "${name}: falha ao descartar alteracoes locais ('git reset --hard' / 'git clean -fd')"
                        Pop-Location
                        continue
                    }
                    $result.DiscardedLocal += "${name}: descartado -> $changedFiles"
                } else {
                    git stash push -u -m "auto-update $(Get-Date -Format 'yyyy-MM-dd HH:mm')" --quiet 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        $result.Errors += "${name}: falha ao guardar alteracoes locais ('git stash')"
                        Pop-Location
                        continue
                    }
                    $result.StashedLocal += "${name}: guardado em stash -> $changedFiles"
                }
            }

            $beforeDescribe = git describe --tags --always 2>$null

            git fetch --all --tags --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                $result.Errors += "${name}: falha no 'git fetch' (verifique VPN/credenciais)"
                Pop-Location
                continue
            }

            $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
            if (-not $upstream -or $LASTEXITCODE -ne 0) {
                $result.SkippedNoUpstream += $name
                Pop-Location
                continue
            }

            $behind = git rev-list "HEAD..$upstream" --count 2>$null
            if ([int]$behind -gt 0) {
                git pull --ff-only --quiet 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $afterDescribe = git describe --tags --always 2>$null
                    $result.Updated += "${name}: $beforeDescribe -> $afterDescribe"
                } else {
                    $result.Errors += "${name}: 'git pull --ff-only' falhou (provavel divergencia, precisa de acao manual)"
                }
            }

            Pop-Location
        } catch {
            $result.Errors += "${name}: erro inesperado - $($_.Exception.Message)"
            try { Pop-Location } catch {}
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLines = @()
    $logLines += "=== Verificacao em $timestamp ==="

    if ($result.VpnAutoConnected) {
        $logLines += "VPN conectada automaticamente (estava desconectada)."
    }
    if ($result.Updated.Count -gt 0) {
        $logLines += "Atualizados:"
        $logLines += ($result.Updated | ForEach-Object { "  - $_" })
    }
    if ($result.DiscardedLocal.Count -gt 0) {
        $logLines += "Alteracoes locais descartadas (reset --hard + clean -fd):"
        $logLines += ($result.DiscardedLocal | ForEach-Object { "  - $_" })
    }
    if ($result.StashedLocal.Count -gt 0) {
        $logLines += "Alteracoes locais guardadas em stash (git stash pop para recuperar):"
        $logLines += ($result.StashedLocal | ForEach-Object { "  - $_" })
    }
    if ($result.SkippedNoUpstream.Count -gt 0) {
        $logLines += "Pulados (sem branch remoto associado):"
        $logLines += ($result.SkippedNoUpstream | ForEach-Object { "  - $_" })
    }
    if ($result.Errors.Count -gt 0) {
        $logLines += "Erros:"
        $logLines += ($result.Errors | ForEach-Object { "  - $_" })
    }
    if ($result.Updated.Count -eq 0 -and $result.DiscardedLocal.Count -eq 0 -and $result.StashedLocal.Count -eq 0 -and $result.SkippedNoUpstream.Count -eq 0 -and $result.Errors.Count -eq 0) {
        $logLines += "Nenhuma novidade."
    }
    $logLines += ""

    Add-Content -Path $logFile -Value ($logLines -join "`r`n") -Encoding utf8

    return $result
}

$configPath = Join-Path $PackageRoot "config.json"
if (-not (Test-Path $configPath)) {
    throw "config.json nao encontrado em $configPath."
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

Write-Host "Verificando modulos, aguarde..." -ForegroundColor Cyan
$result = Invoke-SankhyaUpdate -Config $config -PackageRoot $PackageRoot

if ($result.VpnDown) {
    [System.Windows.Forms.MessageBox]::Show(
        "Nao foi possivel alcancar $($config.gitHost).`n`nVerifique se a VPN esta conectada e rode este atalho novamente.",
        "VPN desconectada",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit
}

$lines = @()
if ($result.Updated.Count -gt 0) {
    $lines += "Atualizados:"
    $lines += ($result.Updated | ForEach-Object { "  - $_" })
    $lines += ""
}
if ($result.DiscardedLocal.Count -gt 0) {
    $lines += "ATENCAO - alteracoes locais descartadas (reset --hard):"
    $lines += ($result.DiscardedLocal | ForEach-Object { "  - $_" })
    $lines += ""
}
if ($result.StashedLocal.Count -gt 0) {
    $lines += "Alteracoes locais guardadas em stash (git stash pop para recuperar):"
    $lines += ($result.StashedLocal | ForEach-Object { "  - $_" })
    $lines += ""
}
if ($result.SkippedNoUpstream.Count -gt 0) {
    $lines += "Pulados (sem branch remoto associado):"
    $lines += ($result.SkippedNoUpstream | ForEach-Object { "  - $_" })
    $lines += ""
}
if ($result.Errors.Count -gt 0) {
    $lines += "Erros:"
    $lines += ($result.Errors | ForEach-Object { "  - $_" })
    $lines += ""
}
if ($lines.Count -eq 0) {
    $lines += "Tudo em dia, nenhuma novidade."
}

$icon = if ($result.Errors.Count -gt 0 -or $result.DiscardedLocal.Count -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }

[System.Windows.Forms.MessageBox]::Show(
    ($lines -join "`n"),
    "Resultado da atualizacao",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    $icon
) | Out-Null

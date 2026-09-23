######################################################################################
# SCRIPT DE INSTALAÇÃO DO GLPI AGENT - WINDOWS
# Autor: Diego Costa (@diegocostaroot) / Projeto Root
# Versão: 1.0
# 2026
#
# Objetivo:
# Instalar e configurar automaticamente o GLPI Agent em máquinas Windows.
#
# Não depende de Active Directory.
#
# Configurações:
#   Server       = servidor GLPI
#   Tag          = nome do computador
#   No SSL Check = habilitado
#
# Executar o PowerShell como Administrador
######################################################################################


# ==========================================================
# CONFIGURAÇÕES
# ==========================================================

$Server = "glpi.empresa.com.br"

$Tag = $env:COMPUTERNAME

$NoSSLCheck = $true


# ==========================================================
# AUTOELEVAÇÃO
# ==========================================================

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {

    Write-Host ""
    Write-Host "Solicitando permissões administrativas..."

    $OriginalScript = $MyInvocation.MyCommand.Path

    if ([string]::IsNullOrWhiteSpace($OriginalScript)) {

        Write-Host ""
        Write-Host "Não foi possível localizar o arquivo do script."
        Write-Host "Execute o arquivo .ps1 diretamente."
        pause
        exit
    }

    $LocalScript = Join-Path `
        $env:TEMP `
        "instalar-glpi-agent.ps1"

    Copy-Item `
        -Path $OriginalScript `
        -Destination $LocalScript `
        -Force

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-ExecutionPolicy Bypass -NoExit -File `"$LocalScript`""

    exit
}


# ==========================================================
# CABEÇALHO
# ==========================================================

Clear-Host

Write-Host ""
Write-Host "=========================================================="
Write-Host "             INSTALAÇÃO DO GLPI AGENT"
Write-Host "=========================================================="
Write-Host ""

Write-Host "Computador : $env:COMPUTERNAME"
Write-Host "Servidor   : $Server"
Write-Host "TAG        : $Tag"
Write-Host "SSL Check  : $NoSSLCheck"
Write-Host ""


# ==========================================================
# VALIDAÇÕES
# ==========================================================

if ([string]::IsNullOrWhiteSpace($Server)) {

    Write-Host "Servidor GLPI não configurado."
    pause
    exit
}

if ([string]::IsNullOrWhiteSpace($Tag)) {

    Write-Host "Não foi possível obter o nome do computador."
    pause
    exit
}


# ==========================================================
# SOLICITA VERSÃO
# ==========================================================

Write-Host "Informe a versão do GLPI Agent que deseja instalar."
Write-Host ""
Write-Host "Exemplo: 1.15"
Write-Host ""

$AgentVersion = Read-Host "Versão do GLPI Agent"

if ([string]::IsNullOrWhiteSpace($AgentVersion)) {

    Write-Host ""
    Write-Host "Versão não informada."
    pause
    exit
}


# ==========================================================
# DIRETÓRIO TEMPORÁRIO
# ==========================================================

$DownloadDir = Join-Path `
    $env:TEMP `
    "GLPI-Agent"

New-Item `
    -Path $DownloadDir `
    -ItemType Directory `
    -Force | Out-Null


# ==========================================================
# DEFINIÇÃO DO INSTALADOR
# ==========================================================

$InstallerName = "GLPI-Agent-$AgentVersion-x64.msi"

$InstallerPath = Join-Path `
    $DownloadDir `
    $InstallerName

$DownloadURL = `
    "https://github.com/glpi-project/glpi-agent/releases/download/$AgentVersion/$InstallerName"


# ==========================================================
# DOWNLOAD
# ==========================================================

Write-Host ""
Write-Host "=========================================================="
Write-Host "DOWNLOAD DO GLPI AGENT"
Write-Host "=========================================================="
Write-Host ""

Write-Host "Versão : $AgentVersion"
Write-Host "Arquivo: $InstallerName"
Write-Host ""

if (Test-Path $InstallerPath) {

    Write-Host "Instalador já existe no diretório temporário."
    Write-Host "Utilizando arquivo existente."

}
else {

    try {

        Write-Host "Baixando instalador..."
        Write-Host ""

        Invoke-WebRequest `
            -Uri $DownloadURL `
            -OutFile $InstallerPath `
            -UseBasicParsing `
            -ErrorAction Stop

        Write-Host "Download concluído."

    }
    catch {

        Write-Host ""
        Write-Host "ERRO AO BAIXAR O GLPI AGENT"
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""

        Write-Host "URL utilizada:"
        Write-Host $DownloadURL
        Write-Host ""

        pause
        exit
    }
}


# ==========================================================
# VERIFICA INSTALADOR
# ==========================================================

if (-not (Test-Path $InstallerPath)) {

    Write-Host ""
    Write-Host "O instalador não foi encontrado."
    pause
    exit
}


$InstallerSize = (
    Get-Item $InstallerPath
).Length


if ($InstallerSize -lt 100KB) {

    Write-Host ""
    Write-Host "O arquivo baixado parece inválido."
    Write-Host "Tamanho: $InstallerSize bytes"
    pause
    exit
}


# ==========================================================
# INSTALAÇÃO
# ==========================================================

Write-Host ""
Write-Host "=========================================================="
Write-Host "INSTALAÇÃO"
Write-Host "=========================================================="
Write-Host ""

Write-Host "Servidor GLPI : $Server"
Write-Host "TAG           : $Tag"
Write-Host "SSL Check     : $NoSSLCheck"
Write-Host ""

Write-Host "Instalando GLPI Agent..."
Write-Host ""


$MSIArguments = @(
    "/i"
    "`"$InstallerPath`""
    "/qn"
    "/norestart"
    "SERVER=$Server"
    "TAG=$Tag"
)


if ($NoSSLCheck) {

    $MSIArguments += "NO_SSL_CHECK=1"
}


$Process = Start-Process `
    -FilePath "msiexec.exe" `
    -ArgumentList $MSIArguments `
    -Wait `
    -PassThru


# ==========================================================
# RESULTADO DA INSTALAÇÃO
# ==========================================================

if ($Process.ExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERRO DURANTE A INSTALAÇÃO"
    Write-Host ""
    Write-Host "Código MSI: $($Process.ExitCode)"
    Write-Host ""

    pause
    exit
}


Write-Host ""
Write-Host "GLPI Agent instalado com sucesso."


# ==========================================================
# LOCALIZA SERVIÇO
# ==========================================================

Write-Host ""
Write-Host "Verificando serviço do GLPI Agent..."

Start-Sleep -Seconds 3

$Service = Get-Service `
    -Name "glpi-agent" `
    -ErrorAction SilentlyContinue


if (-not $Service) {

    Write-Host ""
    Write-Host "ERRO:"
    Write-Host "O serviço glpi-agent não foi encontrado."
    Write-Host ""

    pause
    exit
}


Write-Host ""
Write-Host "Serviço encontrado:"
Write-Host "Nome   : $($Service.Name)"
Write-Host "Status : $($Service.Status)"


# ==========================================================
# INICIA SERVIÇO
# ==========================================================

if ($Service.Status -ne "Running") {

    Write-Host ""
    Write-Host "Iniciando serviço GLPI Agent..."

    try {

        Start-Service `
            -Name "glpi-agent" `
            -ErrorAction Stop

        Write-Host "Serviço iniciado."

    }
    catch {

        Write-Host ""
        Write-Host "Erro ao iniciar o serviço."
        Write-Host $_.Exception.Message

        pause
        exit
    }
}


# ==========================================================
# LOCALIZA EXECUTÁVEL
# ==========================================================

Write-Host ""
Write-Host "Localizando executável do GLPI Agent..."


$AgentExe = Get-ChildItem `
    "C:\Program Files\GLPI-Agent" `
    -Filter "glpi-agent.exe" `
    -Recurse `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1


if (-not $AgentExe) {

    Write-Host ""
    Write-Host "Executável glpi-agent.exe não encontrado."
    Write-Host ""

}
else {

    Write-Host ""
    Write-Host "Executável:"
    Write-Host $AgentExe.FullName
}


# ==========================================================
# INVENTÁRIO INICIAL
# ==========================================================

if ($AgentExe) {

    Write-Host ""
    Write-Host "=========================================================="
    Write-Host "INVENTÁRIO INICIAL"
    Write-Host "=========================================================="
    Write-Host ""

    Write-Host "Enviando inventário para:"
    Write-Host $Server
    Write-Host ""

    $AgentArguments = @(
        "--server=$Server"
        "--tag=$Tag"
    )


    if ($NoSSLCheck) {

        $AgentArguments += "--no-ssl-check"
    }


    try {

        & $AgentExe.FullName @AgentArguments

        $InventoryExitCode = $LASTEXITCODE

        Write-Host ""

        if ($InventoryExitCode -eq 0) {

            Write-Host "Inventário executado com sucesso."

        }
        else {

            Write-Host "O agente retornou código: $InventoryExitCode"
            Write-Host "Verifique os logs do GLPI Agent."
        }

    }
    catch {

        Write-Host ""
        Write-Host "Erro ao executar inventário."
        Write-Host $_.Exception.Message
    }
}


# ==========================================================
# STATUS FINAL
# ==========================================================

Write-Host ""
Write-Host "=========================================================="
Write-Host "INSTALAÇÃO CONCLUÍDA"
Write-Host "=========================================================="
Write-Host ""

$FinalService = Get-Service `
    -Name "glpi-agent" `
    -ErrorAction SilentlyContinue


Write-Host "Computador : $env:COMPUTERNAME"
Write-Host "Servidor   : $Server"
Write-Host "TAG        : $Tag"
Write-Host "SSL Check  : $NoSSLCheck"
Write-Host "Serviço    : $($FinalService.Status)"
Write-Host ""

Write-Host "GLPI Agent instalado e configurado."
Write-Host ""

pause

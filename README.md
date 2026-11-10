# Sankhya Repo Updater

Mantem os repositorios git do Sankhya atualizados todos os dias (`git pull --ff-only`), tanto
os que estao no **GitLab** (`gitlab.sankhya.com.br`, precisa de VPN) quanto os que foram
migrados para o **GitHub** (`github.com/sankhya-tech`).

Tudo fica em **um unico arquivo**: `Sankhya-Repo-Updater.bat`. Ele e ao mesmo tempo um `.bat`
e um script PowerShell legivel - a janela de configuracao, o instalador, a tarefa agendada e o
atalho manual estao todos dentro dele. Nao precisa editar nada a mao.

## Uso

1. De 2 cliques em `Sankhya-Repo-Updater.bat`. Abre uma janela que:
   - procura sozinha os modulos na pasta de projetos (padrao `C:\SK-Code`) e ja deixa marcados;
   - lista tambem os modulos conhecidos que ainda nao existem na maquina (marque para clonar);
   - reconhece modulos migrados do GitLab para o GitHub e mostra "origin sera trocado".
2. Ajuste se quiser: **Conectar a VPN automaticamente** (ja vem marcado), horario e o que fazer
   com alteracoes locais. "Adicionar modulo por URL..." e "Procurar no computador todo" para
   casos fora do padrao.
3. Clique em **Salvar e instalar**. Grava o `config.json` (ao lado do `.bat`), cria a tarefa
   diaria e o atalho na area de trabalho, e oferece atualizar na hora.

No primeiro acesso ao GitHub o login abre no navegador e fica salvo (Git Credential Manager).
A tarefa agendada roda escondida e nunca pede login - sem credencial, so registra no log.

Para mudar algo depois (incluir/remover modulo, horario, VPN), abra o `.bat` de novo e clique
em **Salvar e instalar**.

Linha de comando: `/agora`, `/agendado`, `/status`, `/instalar`, `/desinstalar`.

Quando outro modulo migrar para o GitHub, troque a URL dele em `$KnownRepos`, no topo do `.bat`:
todo mundo que usar o arquivo passa a ter o `origin` trocado sozinho.

## O que acontece com cada repositorio

- **Pasta nao existe** -> `git clone` da `Url` configurada (com `core.longpaths=true`).
- **Pasta existe, `origin` aponta para outro servidor** (ex: projeto migrado do GitLab para o
  GitHub) -> confere se a URL nova responde e so entao troca o `origin`. Se nao responder, o
  `origin` antigo e mantido e o erro vai para o log.
- **Ha commits novos no branch atual** -> `git fetch origin --prune` + `git pull --ff-only`
  (nunca faz merge/rebase). Se o branch local nao existir no novo remoto, o repositorio e
  pulado e o log avisa.
- **Alteracoes locais nao commitadas** -> so sao tocadas quando ha algo para puxar, conforme o
  `DiscardMode`:
  - `'stash'` (padrao, recomendado): `git stash push -u` - recupera com `git stash pop`.
  - `'hard'`: `git reset --hard` + `git clean -fd` - **apaga sem volta**. Como a tarefa roda
    sem supervisao, so use se nunca houver trabalho sem commit nesses repositorios.

## Conexao e VPN

A conexao e testada por servidor. Se a VPN estiver caida, so os repositorios dos servidores
listados em `VpnHosts` ficam de fora naquele dia; os do GitHub continuam sendo atualizados.

Com `VpnAutoConnect = $true`, o script tenta conectar o FortiClient sozinho (clica em
"Conectar" e escolhe a conta `@sankhya.com.br` no SSO do Google, ate 6 tentativas). Requer o
FortiClient **fixado na barra de tarefas** e a sessao de SSO ja autenticada. Com `$false`, so
abre a janela do FortiClient e avisa.

## Logs

`%LOCALAPPDATA%\SankhyaRepoUpdater\logs\update-YYYYMM.log` (botao **Logs** na janela).

## Se algo der errado

- **"git pull --ff-only falhou (provavel divergencia)"**: branch local e remoto divergiram.
  Resolva manualmente com `git pull`/`git rebase` naquele repositorio.
- **"sem acesso a https://github.com/..."** na tarefa agendada: falta login no GitHub. Rode o
  atalho manual 1x.
- **"Filename too long"**: habilite caminhos longos do Windows (PowerShell como Administrador):
  ```powershell
  New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force
  ```

## Editando o arquivo

Mantenha o `.bat` so com caracteres ASCII (sem acentos) e com quebras de linha CRLF - o Windows
PowerShell 5.1 le o arquivo como ANSI e o `cmd` espera CRLF.

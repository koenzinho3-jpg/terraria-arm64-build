#!/bin/bash

# --- 1. CABEÇALHO PADRÃO PORTMASTER ---
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Advanced/Ports/PortMaster" ]; then
  controlfolder="/opt/system/Advanced/Ports/PortMaster"
elif [ -d "/roms/ports/PortMaster" ]; then
  controlfolder="/roms/ports/PortMaster"
elif [ -d "/roms2/ports/PortMaster" ]; then
  controlfolder="/roms2/ports/PortMaster"
else
  controlfolder="/storage/roms/ports/PortMaster"
fi

# Carrega o arquivo de controle do PortMaster (libera a variável $ESUDO)
source $controlfolder/control.txt

# --- 2. DIRETÓRIOS E LOGS ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
gamedir="$SCRIPT_DIR/TerrariaManual"
MNT_MONO="/tmp/mono_terraria"  # Ponto de montagem virtual

# Redireciona a saída para o arquivo de log para análise
> "$SCRIPT_DIR/terraria_manual_debug.txt"
exec > >(tee "$SCRIPT_DIR/terraria_manual_debug.txt") 2>&1

echo "--- Inicializando Montagem Manual do Mono SquashFS ---"

# --- 3. LOCALIZAÇÃO E MONTAGEM DO SQUASHFS ---
MONO_SQUASHFS=""

# Varre os possíveis pontos de montagem do Linux para a pasta de ferramentas do SD
for path in "/tools/PortMaster/libs" "/opt/tools/PortMaster/libs" "/roms/tools/PortMaster/libs" "/roms2/tools/PortMaster/libs" "/storage/tools/PortMaster/libs" "$controlfolder/libs"; do
  if [ -f "$path/mono-6.12.0.122-aarch64.squashfs" ]; then
    MONO_SQUASHFS="$path/mono-6.12.0.122-aarch64.squashfs"
    break
  fi
done

if [ -n "$MONO_SQUASHFS" ]; then
  echo "Arquivo SquashFS encontrado em: $MONO_SQUASHFS"
  
  # Prepara o diretório temporário
  $ESUDO mkdir -p "$MNT_MONO"
  $ESUDO umount -f "$MNT_MONO" 2>/dev/null  # Desmonta se houver sujeira anterior
  
  echo "Montando o sistema de arquivos do Mono..."
  $ESUDO mount -o loop "$MONO_SQUASHFS" "$MNT_MONO"
  
  if [ $? -eq 0 ]; then
    echo "Mono SquashFS montado com sucesso em $MNT_MONO!"
    
    # TRAP: Garante que o Linux vai desmontar o arquivo quando o jogo fechar (ou se o script cair)
    cleanup() {
      echo "Desmontando o ambiente Mono de forma segura..."
      $ESUDO umount -f "$MNT_MONO"
    }
    trap cleanup EXIT
    
    # Injeta os binários e as bibliotecas do SquashFS montado no PATH do sistema
    if [ -d "$MNT_MONO/bin" ]; then
      export PATH="$MNT_MONO/bin:$PATH"
      export LD_LIBRARY_PATH="$MNT_MONO/lib:$LD_LIBRARY_PATH"
    else
      # Ajuste caso a estrutura interna do squashfs use uma subpasta raiz
      export PATH="$MNT_MONO/mono/bin:$PATH"
      export LD_LIBRARY_PATH="$MNT_MONO/mono/lib:$LD_LIBRARY_PATH"
    fi
  else
    echo "ERRO CRÍTICO: Falha ao montar o arquivo SquashFS via loop device."
    exit 1
  fi
else
  echo "ERRO CRÍTICO: Não foi possível mapear o local de 'mono-6.12.0.122-aarch64.squashfs' via Linux."
  exit 1
fi

# --- 4. PREPARAÇÃO DO TERRARIA ---
cd "$gamedir"

echo "Limpando arquivos x86 conflitantes..."
rm -f System*dll
rm -f monoconfig
rm -f monomachineconfig

chmod +x lib64/* 2>/dev/null

# Garante que libSDL3.so.0 existe para o Mono encontrar.
# Tenta symlink primeiro; se o filesystem não suportar (ex: FAT32/exFAT),
# faz uma cópia com o nome correto.
if [ -f "$gamedir/lib64/libSDL3.so.0.4.10" ] && [ ! -e "$gamedir/lib64/libSDL3.so.0" ]; then
  echo "Criando libSDL3.so.0..."
  ln -sf libSDL3.so.0.4.10 "$gamedir/lib64/libSDL3.so.0" 2>/dev/null     || cp "$gamedir/lib64/libSDL3.so.0.4.10" "$gamedir/lib64/libSDL3.so.0"
  echo "libSDL3.so.0 pronto: $(ls -lh $gamedir/lib64/libSDL3.so.0)"
fi

# Prioriza as bibliotecas ARM64 locais que você compilou
export LD_LIBRARY_PATH="$gamedir/lib64:$LD_LIBRARY_PATH"
export MONO_IOMAP=all

# O Mono busca libs nativas no diretório do .exe antes de olhar LD_LIBRARY_PATH.
# Copiamos (ou linkamos) as libs para junto do Terraria.exe para garantir que
# ele as encontre independente do filesystem ou versão do Mono.
echo "Espelhando libs nativas para o diretório do Terraria.exe..."
for lib in "$gamedir/lib64/"*.so*; do
  libname="$(basename "$lib")"
  if [ ! -e "$gamedir/$libname" ]; then
    ln -sf "$lib" "$gamedir/$libname" 2>/dev/null       || cp "$lib" "$gamedir/$libname"
    echo "  + $libname"
  fi
done

# Diagnóstico do sistema — mostra versão da glibc e do kernel
echo "=== DIAGNÓSTICO DO SISTEMA ==="
strings /lib/aarch64-linux-gnu/libm.so.6 2>/dev/null | grep "GLIBC_" | sort -V | tail -5   || strings /lib/libm.so.6 2>/dev/null | grep "GLIBC_" | sort -V | tail -5   || echo "libm não encontrada nos caminhos padrão"
ldd --version 2>&1 | head -1
uname -r
echo "=============================="

echo "Validando disponibilidade do comando 'mono':"
which mono || echo "Aviso: 'mono' ainda não responde no PATH!"

# --- 5. EXECUÇÃO ---
echo "Disparando Mono contra o Terraria.exe..."

# SDL3: força driver de vídeo para kmsdrm (framebuffer DRM — padrão em handhelds)
export SDL_VIDEODRIVER=kmsdrm
export SDL_AUDIODRIVER=alsa

# Evita que o SDL tente abrir um display X11/Wayland inexistente
unset DISPLAY
unset WAYLAND_DISPLAY

# Mantém log de dll ativo para diagnóstico
export MONO_LOG_LEVEL=debug
export MONO_LOG_MASK=dll

run_attempt() {
  local label="$1"
  echo ""
  echo "########################################################"
  echo "### Tentativa [$label]"
  echo "### DEPTHSTENCILFORMAT=${FNA3D_OPENGL_WINDOW_DEPTHSTENCILFORMAT:-<padrao>}"
  echo "### FORCE_ES2=${FNA3D_OPENGL_FORCE_ES2:-0}  FORCE_ES3=${FNA3D_OPENGL_FORCE_ES3:-0}"
  echo "########################################################"

  mono Terraria.exe
  local code=$?
  echo "=== [$label] Mono saiu com código: $code ==="
  if [ $code -ge 128 ]; then
    echo "  -> Sinal $((code - 128)) (crash nativo)"
  fi
  return $code
}

# Tentativa A: ES 2.0 puro + sem VBO_TRASHING (economiza muita RAM) - PADRÃO
echo ""
echo ">>> Testando DEPTHSTENCIL=None + ES2 (Low RAM) - PADRÃO <<<"
export FNA3D_OPENGL_WINDOW_DEPTHSTENCILFORMAT=None
export FNA3D_OPENGL_FORCE_ES2=1
unset FNA3D_OPENGL_FORCE_ES3
unset FNA3D_OPENGL_FORCE_VBO_TRASHING
run_attempt "A: DEPTHSTENCIL=None + ES2 (Low RAM)"
CODE_A=$?

# Tentativa B: Se A falhou, tenta ES3 (mais potente, mas mais RAM)
if [ $CODE_A -ne 0 ]; then
  echo ""
  echo ">>> A falhou — testando DEPTHSTENCIL=None + ES3 (mais RAM) <<<"
  export FNA3D_OPENGL_FORCE_ES3=1
  unset FNA3D_OPENGL_FORCE_ES2
  run_attempt "B: DEPTHSTENCIL=None + ES3"
  CODE_B=$?
fi

# Tentativa C: Se B também falhou, tenta sem nenhuma otimização EGL
if [ $CODE_B -ne 0 ] 2>/dev/null; then
  echo ""
  echo ">>> B falhou — testando sem restrições EGL <<<"
  unset FNA3D_OPENGL_WINDOW_DEPTHSTENCILFORMAT
  unset FNA3D_OPENGL_FORCE_ES3
  unset FNA3D_OPENGL_FORCE_ES2
  run_attempt "C: Sem restrições EGL"
  CODE_C=$?
fi

echo ""
echo "=== Últimas mensagens do kernel (dmesg) ==="
$ESUDO dmesg 2>/dev/null | tail -15 || true

echo ""
echo "Pressione qualquer botão para finalizar e desmontar..."
read -n 1 -s -t 15 || true

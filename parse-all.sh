#!/bin/bash
# =============================================================================
# parse-all.sh - Validasi seluruh file XML di sebuah folder (rekursif, termasuk
#                subfolder) dengan perintah `parse` IIQ console.
#
# Pakai : ./parse-all.sh <folder-xml> <logdir>
#   Contoh: ./parse-all.sh /opt/iiq-deploy/$REL/xml $RD/log
#
# Cara kerja (sesuai IdentityIQ 8.5 Console Guide):
#   - `parse filename`  : validasi satu file terhadap DTD IdentityIQ. Valid = tidak
#                         ada output; tidak valid = runtimeException di console.
#   - `echo text`       : dipakai sebagai penanda file sebelum tiap parse, supaya
#                         error bisa ditelusuri ke file asalnya.
#   - `iiq console -f`  : menjalankan semua perintah dari file lalu keluar
#                         (satu JVM untuk semua file, jauh lebih cepat).
# Read-only: parse tidak menyimpan apa pun ke database.
# Exit 0 = semua file valid, exit 1 = ada file gagal / log tidak lengkap.
# =============================================================================
set -uo pipefail

SRC="${1:?folder XML wajib diisi}"
LOGDIR="${2:?folder log wajib diisi}"
IIQBIN="${IIQBIN:?set dulu IIQBIN=<SPHOME>/WEB-INF/bin}"

[ -d "$SRC" ] || { echo "ERROR: folder $SRC tidak ada"; exit 1; }
mkdir -p "$LOGDIR"
SRC=$(cd "$SRC" && pwd)
LOGDIR=$(cd "$LOGDIR" && pwd)
TS=$(date '+%Y%m%d-%H%M%S')
LIST="$LOGDIR/parse-list-$TS.txt"
CMD="$LOGDIR/parse-cmd-$TS.txt"
LOG="$LOGDIR/parse-$TS.log"
SUM="$LOGDIR/parse-summary-$TS.txt"
MARK="@@PARSE"

# 1) Daftar seluruh XML (rekursif, urut, path absolut)
find "$SRC" -type f -iname '*.xml' | LC_ALL=C sort > "$LIST"
N=$(wc -l < "$LIST")
[ "$N" -eq 0 ] && { echo "ERROR: tidak ada file .xml di $SRC"; exit 1; }

if grep -q '"' "$LIST"; then echo "ERROR: ada path yang mengandung tanda kutip ganda, rename dulu"; exit 1; fi

# 2) Bentuk file perintah console: penanda + parse per file, penanda akhir
{
  while IFS= read -r f; do
    echo "echo $MARK $f"
    echo "parse \"$f\""
  done < "$LIST"
  echo "echo $MARK END"
} > "$CMD"

echo "Parse $N file XML dari $SRC ..."
( cd "$IIQBIN" && ./iiq console -f "$CMD" ) > "$LOG" 2>&1

# 3) Ringkasan: setiap baris setelah penanda dan sebelum penanda berikutnya = output parse file itu
awk -v mark="$MARK" '
  index($0, mark " ") == 1 {
    cur = substr($0, length(mark) + 2)
    if (cur == "END") { ended = 1; cur = ""; next }
    seen++; files[seen] = cur; next
  }
  cur != "" && $0 ~ /[Ee]xception|ERROR|[Ee]rror/ {
    if (!(cur in bad)) { bad[cur] = $0; nbad++ }
  }
  END {
    printf "file_terproses=%d\nfile_gagal=%d\nselesai=%s\n", seen, nbad, (ended ? "ya" : "TIDAK")
    for (i = 1; i <= seen; i++) if (files[i] in bad) printf "GAGAL\t%s\n\t%s\n", files[i], bad[files[i]]
  }' "$LOG" > "$SUM"

DONE=$(grep -c "^$MARK " "$LOG" || true)
EXC_TOTAL=$(grep -ciE 'exception' "$LOG" || true)
{
  echo "folder          : $SRC"
  echo "jumlah file XML : $N"
  echo "log console     : $LOG"
  echo "exception total : $EXC_TOTAL"
  cat "$SUM"
} | tee "$SUM.tmp" && mv "$SUM.tmp" "$SUM"

PROC=$(sed -n 's/^file_terproses=//p' "$SUM")
FAIL=$(sed -n 's/^file_gagal=//p' "$SUM")
FIN=$(sed -n 's/^selesai=//p' "$SUM")

if [ "$PROC" -ne "$N" ] || [ "$FIN" != "ya" ]; then
  echo "HASIL: TIDAK LENGKAP ($PROC dari $N file, cek $LOG - kemungkinan console gagal login/start)"; exit 1
fi
if [ "$FAIL" -gt 0 ] || [ "$EXC_TOTAL" -gt 0 ]; then
  echo "HASIL: GAGAL ($FAIL file bermasalah, lihat daftar GAGAL di atas)"; exit 1
fi
echo "HASIL: OK - $N file valid, log tanpa Exception"
exit 0

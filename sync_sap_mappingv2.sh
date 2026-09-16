#!/bin/bash

# ==============================================================================
# 1. Konfigurasi Variabel
# ==============================================================================
read -rp "Masukkan nama/path file input: " INPUT_FILE

# Validasi apakah input kosong atau file tidak ditemukan
if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: Nama file tidak boleh kosong."
    exit 1
elif [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' tidak ditemukan."
    exit 1
fi
XML_FILE="/tmp/SAP-OA-Mapping.xml"
IIQ_CMD_FILE="/tmp/iiq_commands.txt"

# Direktori instalasi SailPoint IIQ (Sesuaikan dengan path server Anda)
IIQ_BIN_DIR="/opt/tomcat/webapps/identityiq/WEB-INF/bin"

CUSTOM_OBJECT_NAME="SAP-OA-Mapping"
DATE_BACKUP=$(date +"%Y%m%d_%H%M%S")
BACKUP_OBJECT_NAME="${CUSTOM_OBJECT_NAME}-${DATE_BACKUP}"

echo "=== Memulai Proses Konversi Data CSV & Sinkronisasi ==="

# ==============================================================================
# 2. Validasi Ketersediaan File CSV
# ==============================================================================
if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: File input '$INPUT_FILE' tidak ditemukan di direktori saat ini!"
    exit 1
fi
echo "File CSV ditemukan. Memproses ekstraksi ke format List of Maps..."

# ==============================================================================
# 3. Generate Struktur XML Objek Custom SailPoint
# ==============================================================================
echo "Membuat file XML objek Custom baru di $XML_FILE..."

awk -F',' -v customName="$CUSTOM_OBJECT_NAME" '
BEGIN {
    # Header XML dengan struktur List of Maps
    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<!DOCTYPE Custom PUBLIC \"sailpoint.dtd\" \"sailpoint.dtd\">"
    print "<Custom name=\"" customName "\">"
    print "  <Attributes>"
    print "    <Map>"
    print "      <entry key=\"ConnectorConfig\">"
    print "        <value>"
    print "          <Map>"
    print "            <entry key=\"100\" value=\"SAP Direct DEV\"/>"
    print "            <entry key=\"160\" value=\"SAP - User\"/>"
    print "            <entry key=\"170\" value=\"SAP Direct PROD\"/>"
    print "          </Map>"
    print "        </value>"
    print "      </entry>"
    print "      <entry key=\"Mappings\">"
    print "        <value>"
    print "          <List>"
}
NR==1 {
    # Parsing Header
    for (i=1; i<=NF; i++) {
        col = tolower($i)
        gsub(/^[ \t\r\n"]+|[ \t\r\n"]+$/, "", col)
        if (col == "positionid" || col == "position id") pos_idx = i
        else if (col == "company code" || col == "companycode") comp_idx = i
        else if (col == "client") client_idx = i
        else if (col == "compositerole" || col == "composite role") role_idx = i
    }
    if (!pos_idx) pos_idx = 1; if (!comp_idx) comp_idx = 2
    if (!client_idx) client_idx = 3; if (!role_idx) role_idx = 4
    next
}
{
    sub(/\r$/, "")
    if (length($0) == 0) next
    
    pos = $pos_idx; comp = $comp_idx; cli = $client_idx; role = $role_idx
    gsub(/(^"|"$)/, "", pos); gsub(/(^"|"$)/, "", comp)
    gsub(/(^"|"$)/, "", cli); gsub(/(^"|"$)/, "", role)
    
    # Sanitasi karakter khusus XML (<, >, &)
    gsub(/&/, "\\&amp;", pos); gsub(/</, "\\&lt;", pos); gsub(/>/, "\\&gt;", pos)
    gsub(/&/, "\\&amp;", comp); gsub(/</, "\\&lt;", comp); gsub(/>/, "\\&gt;", comp)
    gsub(/&/, "\\&amp;", cli); gsub(/</, "\\&lt;", cli); gsub(/>/, "\\&gt;", cli)
    gsub(/&/, "\\&amp;", role); gsub(/</, "\\&lt;", role); gsub(/>/, "\\&gt;", role)
    
    if (pos == "" && comp == "") next
    
    # Menulis setiap baris CSV sebagai satu <Map> utuh dengan penyesuaian penamaan key
    print  "            <Map>"
    printf "              <entry key=\"positionId\" value=\"%s\"/>\n", pos
    printf "              <entry key=\"companyCode\" value=\"%s\"/>\n", comp
    printf "              <entry key=\"client\" value=\"%s\"/>\n", cli
    printf "              <entry key=\"sapCompositeRole\" value=\"%s\"/>\n", role
    print  "            </Map>"
}
END {
    # Penutup tag XML
    print "          </List>"
    print "        </value>"
    print "      </entry>"
    print "    </Map>"
    print "  </Attributes>"
    print "</Custom>"
}
' "$INPUT_FILE" > "$XML_FILE"

# ==============================================================================
# 4. Siapkan Perintah IIQ Console (Login, Rename, Import)
# ==============================================================================
echo "Menyiapkan instruksi console..."
cat <<EOF > "$IIQ_CMD_FILE"
spadmin
P@ssw0rd
# Ubah nama objek yang saat ini berjalan di database menjadi versi backup
rename Custom "$CUSTOM_OBJECT_NAME" "$BACKUP_OBJECT_NAME"

# Import objek data hasil XML yang terbaru
import "$XML_FILE"

quit
EOF

# ==============================================================================
# 5. Eksekusi IIQ Console
# ==============================================================================
echo "Masuk ke direktori IIQ bin: $IIQ_BIN_DIR"
cd "$IIQ_BIN_DIR" || { echo "Direktori IIQ bin tidak ditemukan!"; exit 1; }

echo "Mengeksekusi backup dan import ke database SailPoint..."
./iiq console < "$IIQ_CMD_FILE"

echo "=== Proses Selesai! Data terbaru ada di '$CUSTOM_OBJECT_NAME' dan data lama tersimpan di '$BACKUP_OBJECT_NAME'. ==="

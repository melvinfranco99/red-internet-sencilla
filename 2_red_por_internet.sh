#!/bin/bash
# =============================================================================
#  2_red_por_internet.sh
#
#  Basado en 1_red_4_routers_en_anillo.sh, pero ahora las dos LANs NO se
#  conocen entre sí: están separadas por "Internet".
#
#  Esquema:
#
#   LAN casa A (privada)                 INTERNET (IPs públicas)                  LAN casa B (privada)
#  ┌────────────────────┐   ┌──────────────────────────────────────────────┐   ┌────────────────────┐
#  │ pc1 ── sw1 ── r1 ──┼───┼── isp1 ═══════════════ isp2 ─────────────────┼───┼── r4 ── sw4 ── pc4 │
#  └────────────────────┘   └──────────────────────────────────────────────┘   └────────────────────┘
#   10.10.10.0/24            203.0.113.0/24   192.0.2.0/24   198.51.100.0/24     10.10.40.0/24
#
#  Direcciones:
#   pc1   10.10.10.10   (privada)          gateway -> r1 10.10.10.1
#   r1    10.10.10.1    (LAN)  | 203.0.113.10  (WAN, IP pública de la casa A)
#   isp1  203.0.113.1   (hacia r1)   | 192.0.2.1 (troncal hacia isp2)
#   isp2  192.0.2.2     (troncal)    | 198.51.100.1 (hacia r4)
#   r4    198.51.100.10 (WAN, IP pública de la casa B) | 10.10.40.1 (LAN)
#   pc4   10.10.40.10   (privada)          gateway -> r4 10.10.40.1
#
#  Diferencias con el script 1:
#   - Se eliminan r2 y r3 (y con ellos pc2/pc3/sw2/sw3, que colgaban de ellos).
#   - r1 y r4 ya NO tienen rutas hacia la LAN del otro. Solo tienen una
#     "ruta por defecto" hacia su proveedor (ISP): "todo lo que no conozca,
#     mándalo a Internet".
#   - Los routers de Internet (isp1, isp2) solo conocen IPs PÚBLICAS.
#     Nunca sabrán llegar a una 10.x.x.x (igual que en el Internet real).
#   - Para que funcione hace falta NAT:
#       * r1 hace SNAT/MASQUERADE: los paquetes de pc1 salen con la IP
#         pública de r1 (203.0.113.10) en vez de con 10.10.10.10.
#       * r4 hace DNAT (port forwarding): lo que llegue a 198.51.100.10:8080
#         lo reenvía a pc4 (10.10.40.10:80), donde hay un servidor web.
#
#  IPs "públicas" usadas: 192.0.2.0/24, 198.51.100.0/24 y 203.0.113.0/24 son
#  los rangos reservados para documentación (RFC 5737). Se comportan como
#  IPs públicas normales pero no pertenecen a nadie real, así que no chocan
#  con ninguna web de verdad.
#
#  Uso:   sudo bash 2_red_por_internet.sh
# =============================================================================

set -e   # si un comando falla, el script se para (así ves el error)

if [ "$EUID" -ne 0 ]; then
	echo "Ejecútalo como root:  sudo bash $0"
	exit 1
fi

# -----------------------------------------------------------------------------
# 0) Limpiar lo anterior
#    Solo borramos NUESTROS namespaces y NUESTROS bridges (sw1..sw4).
#    Ojo: el script 1 borraba TODOS los bridges del sistema, incluido docker0.
# -----------------------------------------------------------------------------
for ns in pc1 pc2 pc3 pc4 r1 r2 r3 r4 isp1 isp2; do
	if ip netns list | grep -qw "$ns"; then
		echo "Eliminando namespace: $ns"
		# Matamos los procesos que vivan dentro (p. ej. el servidor web de pc4),
		# si no, el namespace seguiría vivo en segundo plano.
		ip netns pids "$ns" | xargs -r kill -9 2>/dev/null || true
		ip netns del "$ns"
	fi
done

for br in sw1 sw2 sw3 sw4; do
	if ip link show "$br" &>/dev/null; then
		echo "Eliminando bridge: $br"
		ip link set "$br" down
		ip link del "$br" type bridge
	fi
done

# -----------------------------------------------------------------------------
# 1) Creación de dispositivos
#    - namespace = un "ordenador/router" aislado con su propia pila de red
#    - bridge    = un switch
# -----------------------------------------------------------------------------
# Casa A
ip netns add pc1
ip link add sw1 type bridge
ip netns add r1       # router de casa A (el "router de Movistar/Vodafone")

# Internet
ip netns add isp1     # router del proveedor de la casa A
ip netns add isp2     # router del proveedor de la casa B

# Casa B
ip netns add r4       # router de casa B
ip link add sw4 type bridge
ip netns add pc4

# -----------------------------------------------------------------------------
# 2) Creación del cableado (veth = cable con dos extremos)
# -----------------------------------------------------------------------------
# Casa A
ip link add veth_pc1_sw1 type veth peer name veth_sw1_pc1
ip link add veth_sw1_r1  type veth peer name veth_r1_sw1
# Salida a Internet de la casa A (la "fibra" hasta el ISP)
ip link add veth_r1_isp1 type veth peer name veth_isp1_r1
# Troncal de Internet entre los dos proveedores
ip link add veth_isp1_isp2 type veth peer name veth_isp2_isp1
# Salida a Internet de la casa B
ip link add veth_isp2_r4 type veth peer name veth_r4_isp2
# Casa B
ip link add veth_sw4_r4  type veth peer name veth_r4_sw4
ip link add veth_pc4_sw4 type veth peer name veth_sw4_pc4

# -----------------------------------------------------------------------------
# 3) Conexión del cableado (meter cada extremo en su sitio)
# -----------------------------------------------------------------------------
# Casa A
ip link set veth_pc1_sw1 netns pc1
ip link set veth_sw1_pc1 master sw1
ip link set veth_sw1_r1  master sw1
ip link set veth_r1_sw1  netns r1
ip link set veth_r1_isp1 netns r1

# Internet
ip link set veth_isp1_r1   netns isp1
ip link set veth_isp1_isp2 netns isp1
ip link set veth_isp2_isp1 netns isp2
ip link set veth_isp2_r4   netns isp2

# Casa B
ip link set veth_r4_isp2 netns r4
ip link set veth_r4_sw4  netns r4
ip link set veth_sw4_r4  master sw4
ip link set veth_sw4_pc4 master sw4
ip link set veth_pc4_sw4 netns pc4

# -----------------------------------------------------------------------------
# 4) Dar de alta todos los enlaces (por defecto nacen "apagados")
# -----------------------------------------------------------------------------
# Lo que queda en el host: los switches y sus puertos
ip link set up dev sw1
ip link set up dev sw4
ip link set up dev veth_sw1_pc1
ip link set up dev veth_sw1_r1
ip link set up dev veth_sw4_r4
ip link set up dev veth_sw4_pc4

# La interfaz loopback (127.0.0.1) de cada namespace
for ns in pc1 r1 isp1 isp2 r4 pc4; do
	ip netns exec "$ns" ip link set up dev lo
done

ip netns exec pc1  ip link set up dev veth_pc1_sw1
ip netns exec r1   ip link set up dev veth_r1_sw1
ip netns exec r1   ip link set up dev veth_r1_isp1
ip netns exec isp1 ip link set up dev veth_isp1_r1
ip netns exec isp1 ip link set up dev veth_isp1_isp2
ip netns exec isp2 ip link set up dev veth_isp2_isp1
ip netns exec isp2 ip link set up dev veth_isp2_r4
ip netns exec r4   ip link set up dev veth_r4_isp2
ip netns exec r4   ip link set up dev veth_r4_sw4
ip netns exec pc4  ip link set up dev veth_pc4_sw4

# -----------------------------------------------------------------------------
# 5) Poner IPs
#    Privadas (10.x) dentro de cada casa, públicas en todo lo que toca Internet.
# -----------------------------------------------------------------------------
# Casa A (privada)
ip netns exec pc1  ip addr add 10.10.10.10/24   dev veth_pc1_sw1
ip netns exec r1   ip addr add 10.10.10.1/24    dev veth_r1_sw1
# Enlace casa A <-> ISP1 (pública)
ip netns exec r1   ip addr add 203.0.113.10/24  dev veth_r1_isp1   # IP pública de la casa A
ip netns exec isp1 ip addr add 203.0.113.1/24   dev veth_isp1_r1
# Troncal ISP1 <-> ISP2 (pública)
ip netns exec isp1 ip addr add 192.0.2.1/24     dev veth_isp1_isp2
ip netns exec isp2 ip addr add 192.0.2.2/24     dev veth_isp2_isp1
# Enlace ISP2 <-> casa B (pública)
ip netns exec isp2 ip addr add 198.51.100.1/24  dev veth_isp2_r4
ip netns exec r4   ip addr add 198.51.100.10/24 dev veth_r4_isp2   # IP pública de la casa B
# Casa B (privada)
ip netns exec r4   ip addr add 10.10.40.1/24    dev veth_r4_sw4
ip netns exec pc4  ip addr add 10.10.40.10/24   dev veth_pc4_sw4

# -----------------------------------------------------------------------------
# 6) Rutas
#    Las redes "directamente conectadas" se aprenden solas al poner la IP.
#    Solo hay que añadir lo que NO está conectado directamente.
# -----------------------------------------------------------------------------
# Los PCs: todo lo que no sea su LAN, al router de casa
ip netns exec pc1 ip route add default via 10.10.10.1 dev veth_pc1_sw1
ip netns exec pc4 ip route add default via 10.10.40.1 dev veth_pc4_sw4

# Los routers de casa: todo lo que no conozcan, a su ISP (a Internet).
# ¡Fíjate que ya NO hay "ip route add 10.10.40.0/24 ..." como en el script 1!
ip netns exec r1 ip route add default via 203.0.113.1  dev veth_r1_isp1
ip netns exec r4 ip route add default via 198.51.100.1 dev veth_r4_isp2

# Los routers de Internet solo se pasan rutas de redes PÚBLICAS.
# (En el Internet real esto lo hace BGP automáticamente; aquí lo ponemos a mano)
ip netns exec isp1 ip route add 198.51.100.0/24 via 192.0.2.2 dev veth_isp1_isp2
ip netns exec isp2 ip route add 203.0.113.0/24  via 192.0.2.1 dev veth_isp2_isp1

# -----------------------------------------------------------------------------
# 7) Activar el reenvío de paquetes (convertir los namespaces en routers)
# -----------------------------------------------------------------------------
for ns in r1 isp1 isp2 r4; do
	ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1
done

# -----------------------------------------------------------------------------
# 8) Internet "de verdad" no deja pasar IPs privadas
#    Los ISPs tiran cualquier paquete con origen o destino 10.0.0.0/8.
#    Así se ve claro que SIN NAT no se llega a ningún sitio.
# -----------------------------------------------------------------------------
for ns in isp1 isp2; do
	ip netns exec "$ns" iptables -A FORWARD -s 10.0.0.0/8 -j DROP
	ip netns exec "$ns" iptables -A FORWARD -d 10.0.0.0/8 -j DROP
done

# -----------------------------------------------------------------------------
# 9) NAT
# -----------------------------------------------------------------------------
# 9.a) SNAT / MASQUERADE en los routers de casa (salida a Internet)
#      "Todo lo que venga de mi LAN y salga por la interfaz de Internet,
#       cámbiale la IP de origen por mi IP pública".
#      r1 apunta en su tabla conntrack quién pidió qué, para devolver la
#      respuesta al PC correcto.
ip netns exec r1 iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o veth_r1_isp1 -j MASQUERADE
ip netns exec r4 iptables -t nat -A POSTROUTING -s 10.10.40.0/24 -o veth_r4_isp2 -j MASQUERADE

# 9.b) DNAT / "abrir puertos" en r4 (entrada desde Internet)
#      "Lo que llegue desde Internet a mi puerto 8080 TCP, mándalo a
#       pc4 (10.10.40.10) al puerto 80".
ip netns exec r4 iptables -t nat -A PREROUTING -i veth_r4_isp2 -p tcp --dport 8080 \
	-j DNAT --to-destination 10.10.40.10:80

# -----------------------------------------------------------------------------
# 10) Servidor web en pc4 (puerto 80) para probar con curl
# -----------------------------------------------------------------------------
WEB=/tmp/web_pc4
mkdir -p "$WEB"
cat > "$WEB/index.html" <<'EOF'
Hola, soy pc4 (10.10.40.10). Si lees esto, has cruzado Internet :)
EOF
# setsid + redirecciones: el servidor queda en segundo plano aunque cierres la terminal
setsid ip netns exec pc4 python3 -m http.server 80 --bind 10.10.40.10 --directory "$WEB" \
	>/dev/null 2>&1 < /dev/null &
# Esperamos (máx. 5 s) a que el servidor esté escuchando en el puerto 80
for i in $(seq 50); do
	ip netns exec pc4 ss -ltn | grep -q ':80 ' && break
	sleep 0.1
done

echo
echo "Red montada. Pruebas rápidas:"
echo "  sudo ip netns exec pc1 ping -c 3 198.51.100.10          # IP pública del router de pc4"
echo "  sudo ip netns exec pc1 curl http://198.51.100.10:8080    # web de pc4 a través de Internet"
echo "  sudo ip netns exec pc1 ping -c 3 -W 1 10.10.40.10       # debe FALLAR (IP privada)"

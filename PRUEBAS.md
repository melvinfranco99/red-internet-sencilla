# Cómo comprobar que funciona

## 0. Montar la red

```bash
cd red_internet_sencilla
sudo bash 2_red_por_internet.sh
```

## 1. Ping a la IP pública del router de pc4 (debe funcionar)

```bash
sudo ip netns exec pc1 ping -c 3 198.51.100.10
```

pc1 (10.10.10.10) → r1 lo traduce a 203.0.113.10 → isp1 → isp2 → r4 responde.

## 2. curl a pc4 por IP pública y puerto (debe funcionar)

```bash
sudo ip netns exec pc1 curl http://198.51.100.10:8080
# Hola, soy pc4 (10.10.40.10). Si lees esto, has cruzado Internet :)
```

r4 recibe en su puerto 8080 y lo reenvía (DNAT) a 10.10.40.10:80.

## 3. Ping a la IP privada de pc4 (debe FALLAR)

```bash
sudo ip netns exec pc1 ping -c 3 -W 1 10.10.40.10
```

Internet (isp1/isp2) no tiene ruta hacia 10.x.x.x. Por eso existe el NAT.

## 4. Ver los saltos por Internet

```bash
sudo ip netns exec pc1 tracepath -n 198.51.100.10
#  1: 10.10.10.1      (r1)
#  2: 203.0.113.1     (isp1)
#  3: 192.0.2.2       (isp2)
#  4: 198.51.100.10   (r4) alcanzado
```

## 5. Ver el NAT en acción

Terminal A (escucha en pc4):

```bash
sudo ip netns exec pc4 tcpdump -ni veth_pc4_sw4 tcp port 80
```

Terminal B:

```bash
sudo ip netns exec pc1 curl http://198.51.100.10:8080
```

En la terminal A verás `203.0.113.10.xxxxx > 10.10.40.10.80`: pc4 **no** ve a
10.10.10.10, ve la IP pública de la casa A.

Lo mismo en Internet (isp1), durante un ping:

```bash
sudo ip netns exec isp1 tcpdump -ni veth_isp1_r1 icmp
```

## 6. Mirar las tablas de traducción (conntrack) y los contadores

```bash
sudo ip netns exec r1 cat /proc/net/nf_conntrack
sudo ip netns exec r1 iptables -t nat -L -n -v
sudo ip netns exec r4 iptables -t nat -L -n -v
```

## 7. Experimento: quitar el NAT y ver que se rompe

```bash
# quitar
sudo ip netns exec r1 iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o veth_r1_isp1 -j MASQUERADE
sudo ip netns exec pc1 ping -c 2 -W 1 198.51.100.10     # ahora FALLA
# volver a ponerlo
sudo ip netns exec r1 iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o veth_r1_isp1 -j MASQUERADE
sudo ip netns exec pc1 ping -c 2 198.51.100.10          # vuelve a funcionar
```

## 8. Al revés: pc4 también sale a Internet

```bash
sudo ip netns exec pc4 ping -c 3 203.0.113.10
```

## Limpiar

```bash
for ns in pc1 pc4 r1 r4 isp1 isp2; do
  sudo ip netns pids $ns | xargs -r sudo kill -9
  sudo ip netns del $ns
done
sudo ip link del sw1; sudo ip link del sw4
```

(El script también limpia todo solo si lo vuelves a ejecutar.)

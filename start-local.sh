#!/usr/bin/env bash
#
# Levanta los 3 microservicios del SSO (auth-center, sso-admin, api-gateway)
# en background, nativos (sin Docker). Útil cuando quieres iterar rápido
# sin tirar de docker compose.
#
# Pre-requisitos:
#   - Postgres corriendo (sso-postgres en localhost:5432)
#   - Eureka corriendo (eurekaserver.jar, ver start-eureka.sh si aplica)
#   - JARs ya compilados:
#     mvn -q -pl common,api-gateway,auth-center,sso-admin -am clean install -DskipTests
#
# Uso:
#   ./start-local.sh           # arranca los 3 servicios
#   ./start-local.sh stop      # mata los 3 servicios (alias de stop-local.sh)
#   ./start-local.sh status    # muestra qué está corriendo
#   ./start-local.sh logs      # tail -f de los 3 logs
#   ./start-local.sh clean     # mata zombies (PIDs sin "java -jar" en cmdline)
#
# Credenciales admin seedeadas por DataInitializer:
#   admin / ChangeMe-Now-Please-123!

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="${LOG_DIR:-/tmp}"
EUREKA_HOSTNAME="${EUREKA_INSTANCE_HOSTNAME:-localhost}"

# Servicios a arrancar: nombre=jar_relativo=puerto=main_class
# El main_class se usa para detectar zombies que el IDE pueda haber
# dejado vivos (esos arrancan con classpath absoluto, no con "java -jar").
SERVICES=(
  "auth-center:auth-center/target/auth-center.jar:8081:com.co.eurekatic.auth.AuthCenterApplication"
  "sso-admin:sso-admin/target/sso-admin.jar:8083:com.co.eurekatic.ssoadmin.SsoAdminApplication"
  "api-gateway:api-gateway/target/api-gateway.jar:8080:com.co.eurekatic.gateway.ApiGatewayApplication"
  "notification-service:notification-service/target/notification-service.jar:8085:com.co.eurekatic.notificationservice.NotificationServiceApplication"
)

# Devuelve los PIDs (uno por línea) que matchean un servicio, ya sea
# por cmdline "java -jar <jar>" o por main class directo (zombie IDE).
find_pids() {
  local jar="$1" main_class="$2"
  {
    pgrep -f "java -jar ${jar}" 2>/dev/null || true
    pgrep -f "java .*${main_class}" 2>/dev/null || true
  } | sort -u
}

cmd="${1:-start}"

case "$cmd" in
  stop)
    echo "Stopping services..."
    for entry in "${SERVICES[@]}"; do
      IFS=':' read -r name jar _ _ <<< "$entry"
      pids=$(find_pids "$jar" "$(echo "$entry" | cut -d: -f4)")
      if [ -n "$pids" ]; then
        echo "  $name (PIDs: $(echo $pids | tr '\n' ' '))"
        echo "$pids" | xargs kill 2>/dev/null || true
      else
        echo "  $name: not running"
      fi
    done
    exit 0
    ;;

  clean)
    echo "Killing zombie processes (IDE leftover, no 'java -jar' in cmdline)..."
    for entry in "${SERVICES[@]}"; do
      IFS=':' read -r name jar _ main_class <<< "$entry"
      pids=$(pgrep -f "${main_class}" 2>/dev/null || true)
      if [ -n "$pids" ]; then
        # Solo matar los que NO tienen "java -jar" en cmdline
        for pid in $pids; do
          cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
          if ! echo "$cmdline" | grep -q "java -jar"; then
            echo "  Zombie $name (PID $pid): killing"
            kill -9 "$pid" 2>/dev/null || true
          fi
        done
      fi
    done
    exit 0
    ;;

  status)
    echo "Service status:"
    for entry in "${SERVICES[@]}"; do
      IFS=':' read -r name jar port main_class <<< "$entry"
      pids=$(find_pids "$jar" "$main_class")
      if [ -n "$pids" ]; then
        pid=$(echo "$pids" | head -1)
        echo "  $name (port $port): UP (PID $pid)"
      else
        echo "  $name (port $port): DOWN"
      fi
    done
    exit 0
    ;;

  logs)
    logs=()
    for entry in "${SERVICES[@]}"; do
      IFS=':' read -r name _ _ _ <<< "$entry"
      logs+=("$LOG_DIR/${name}.log")
    done
    exec tail -f "${logs[@]}"
    ;;

  start) ;;

  *)
    echo "Uso: $0 [start|stop|status|logs|clean]" >&2
    exit 1
    ;;
esac

# Verificar JARs
echo "Verificando JARs..."
for entry in "${SERVICES[@]}"; do
  IFS=':' read -r name jar _ _ <<< "$entry"
  if [ ! -f "$jar" ]; then
    echo "ERROR: $jar no existe. Compila primero con:" >&2
    echo "  mvn -q -pl common,api-gateway,auth-center,sso-admin -am clean install -DskipTests" >&2
    exit 1
  fi
done

# Verificar pre-requisitos
echo "Verificando pre-requisitos..."
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^sso-postgres$'; then
  echo "ADVERTENCIA: contenedor sso-postgres no detectado en Docker." >&2
fi
if ! curl -sf -o /dev/null --max-time 2 http://localhost:8761/eureka/apps 2>/dev/null; then
  echo "ADVERTENCIA: Eureka no responde en localhost:8761." >&2
  echo "  Arranca eurekaserver.jar primero si quieres que el registro funcione." >&2
fi

# Limpiar zombies del IDE automáticamente (estos bloquean los puertos
# sin que el script los detecte por cmdline "java -jar").
echo "Limpiando zombies del IDE..."
for entry in "${SERVICES[@]}"; do
  IFS=':' read -r name jar _ main_class <<< "$entry"
  for pid in $(pgrep -f "${main_class}" 2>/dev/null || true); do
    cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if ! echo "$cmdline" | grep -q "java -jar"; then
      echo "  Zombie $name (PID $pid): matando"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
done

# Arrancar
echo ""
echo "Arrancando servicios con EUREKA_INSTANCE_HOSTNAME=$EUREKA_HOSTNAME..."
for entry in "${SERVICES[@]}"; do
  IFS=':' read -r name jar port main_class <<< "$entry"
  pids=$(find_pids "$jar" "$main_class")
  if [ -n "$pids" ]; then
    echo "  $name (port $port): ya corriendo, skip"
    continue
  fi
  echo "  $name (port $port): arrancando..."
  EUREKA_INSTANCE_HOSTNAME="$EUREKA_HOSTNAME" \
    nohup java -jar "$jar" > "$LOG_DIR/${name}.log" 2>&1 &
  disown || true
done

echo ""
echo "Esperando que arranquen..."
sleep 8

# Mostrar estado
echo ""
"$0" status

echo ""
echo "Logs en: $LOG_DIR/{auth-center,sso-admin,api-gateway,notification-service}.log"
echo "Sigue con: $0 logs"
echo ""
echo "Credenciales: admin / ChangeMe-Now-Please-123!"
echo "Probar: curl -X POST http://localhost:8080/api/auth/login -H 'Content-Type: application/json' -d '{\"username\":\"admin\",\"password\":\"ChangeMe-Now-Please-123!\"}'"

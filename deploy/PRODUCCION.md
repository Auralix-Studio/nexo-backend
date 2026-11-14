# Llevar Nexo a producción — paso a paso

Orden: **1 MongoDB → 2 Azure → 3 Atlas → 4 Hostinger → 5 APK → 6 pruebas → 7 publicar**.
Tiempo aproximado: 45–60 min (más la espera del DNS).

Rutas usadas abajo:

- Backend: `C:\Users\aless\Desktop\dev\Auralix\nexo\nexo-backend`
- App: `C:\Users\aless\Desktop\dev\Auralix\nexo\nexo-code`

Los comandos se ejecutan en **Git Bash** (el script de despliegue es bash).

---

## 1. MongoDB Atlas: base de producción

Entra a <https://cloud.mongodb.com> con tu cuenta.

1. Elige el proyecto y el clúster que ya usas (o crea uno nuevo si quieres
   separar producción de desarrollo; el plan M0 gratis alcanza para empezar).
2. **Security → Database Access → Add New Database User**
   - Authentication: Password. Usuario, por ejemplo, `nexo-prod`. Contraseña:
     usa *Autogenerate Secure Password* y cópiala.
   - Built-in role: **Read and write to any database** (o, mejor, *Specific
     privileges* → `readWrite` sobre la base `nexo`).
3. **Database → Connect → Drivers** y copia la cadena. Se ve así:
   `mongodb+srv://nexo-prod:<password>@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0`
4. Cambia `<password>` por la contraseña y agrega el nombre de la base antes
   del `?`:
   `mongodb+srv://nexo-prod:LA_CLAVE@cluster0.xxxxx.mongodb.net/nexo?retryWrites=true&w=majority&appName=Cluster0`
   Si la contraseña tiene `@ : / ? # %`, cámbiala por otra sin esos signos.
5. Abre `nexo-backend\deploy\azure\.env.production` (ya lo dejé creado, con
   `SECRET_KEY_BASE` y `ADMIN_API_KEY` generadas) y pega la cadena en
   `MONGODB_URI=`, sin comillas.
6. (Opcional) En `SYSTEM_ADMINS=` pon tu código o DNI: es quien puede repartir
   el acceso al directorio de estudiantes. Guarda el archivo.

No subas ese archivo a ningún lado: está ignorado por git y por Docker.

## 2. Azure: desplegar el backend

Ya tienes la CLI instalada y la sesión iniciada en *Azure for Students*.

```bash
cd /c/Users/aless/Desktop/dev/Auralix/nexo/nexo-backend
az account show --query name -o tsv
```

Debe decir `Azure for Students`. Si no: `az login`.

```bash
bash deploy/azure/deploy.sh
```

Tarda 5–10 minutos. Crea en el grupo **Nexo** (Chile Central): el registro de
imágenes, el entorno y la app `nexo-api`. Al final muestra:

- `fqdn`: algo como `nexo-api.<algo>.chilecentral.azurecontainerapps.io`
  (anótalo);
- `outbound IPs`: una o varias IPs (anótalas).

Puedes verlo también en <https://portal.azure.com> → *Grupos de recursos* →
**Nexo** → **nexo-api**.

## 3. Atlas: dejar entrar a Azure

En <https://cloud.mongodb.com> → **Security → Network Access → Add IP
Address**: agrega **cada** IP de salida que mostró el paso 2 (comentario:
`Azure nexo-api`).

Comprueba (en el navegador o con curl):

```bash
curl https://<fqdn>/health
```

Debe responder `{"status":"ok","db":"ok"}`. Si dice `db` con error, revisa la
IP en Atlas y la cadena `MONGODB_URI`. La primera respuesta puede tardar unos
segundos (el contenedor arranca desde cero).

> Las IPs de salida de Azure pueden cambiar si se recrea el entorno. Si algún
> día `/health` da error de base de datos, ejecuta
> `bash deploy/azure/deploy.sh status` y vuelve a agregar las IPs nuevas.

## 4. Hostinger: el dominio `api.nexo.aurx.pro`

```bash
bash deploy/azure/deploy.sh domain
```

El script imprime dos registros y **se queda esperando**. Sin cerrarlo:

1. Entra a <https://hpanel.hostinger.com> → **Dominios** → `aurx.pro` →
   **DNS / Nameservers** → *Administrar registros DNS*.
2. Agrega:

   | Tipo | Nombre | Apunta a / Valor | TTL |
   | --- | --- | --- | --- |
   | CNAME | `api.nexo` | el `fqdn` que mostró el script | 300 |
   | TXT | `asuid.api.nexo` | el código de verificación que mostró el script | 300 |

   En *Nombre* va solo `api.nexo` (Hostinger agrega `.aurx.pro`).
3. Comprueba desde otra terminal hasta que responda (5–30 min):

   ```bash
   nslookup api.nexo.aurx.pro
   ```

4. Vuelve a la terminal del script y presiona **Enter**. Crea el certificado
   HTTPS gratis y desde ese momento la API solo responde en
   `api.nexo.aurx.pro`.

Comprueba: abre <https://api.nexo.aurx.pro/status> → debe responder
`{"ok":true,…}`.

## 5. Compilar el APK

```bash
cd /c/Users/aless/Desktop/dev/Auralix/nexo/nexo-code
git checkout feat/backend-gateway
flutter build apk --release
```

El APK queda en
`nexo-code\build\app\outputs\flutter-apk\app-release.apk`. Se firma con tu
llave de siempre (`android/key.properties`), así que se instala encima de la
versión actual sin desinstalar.

La app ya apunta a `https://api.nexo.aurx.pro` por defecto. Para probar contra
otra dirección (por ejemplo el `fqdn` de Azure antes de tener el dominio):

```bash
flutter build apk --release --dart-define=NEXO_BACKEND_URL=https://<fqdn>
```

## 6. Pruebas con cuentas reales

Instala el APK y prueba, en este orden. Anota cualquier pantalla vacía o
error:

**Estudiante**

- [ ] Iniciar sesión, y cerrar e iniciar de nuevo.
- [ ] Inicio: promedio del ciclo, próximas clases, monto por pagar.
- [ ] Horario (y clases de Idiomas si tiene).
- [ ] Notas del ciclo actual, detalle de un curso, un ciclo anterior.
- [ ] Récord / avance curricular.
- [ ] Pagos: pendientes, vencidos, historial, cronograma.
- [ ] Constancia de matrícula (PDF), publicaciones, wifi.

**Docente**

- [ ] Iniciar sesión.
- [ ] Ver secciones, lista de alumnos, unidades.
- [ ] Registrar **una** nota de prueba y verificar en SIGMA web que llegó.
- [ ] Tomar asistencia en una sesión y verificar en SIGMA web.
- [ ] Descargar el registro auxiliar.
- [ ] Clases virtuales / marcación si aplica.

Si algo falla, los registros están en
<https://portal.azure.com> → **nexo-api** → *Supervisión* → **Secuencia de
registro** (Log stream). Cada error de la app trae un `request_id` que aparece
ahí.

Puntos aún sin confirmar con datos reales (revisar con atención): guardar notas
y asistencia del docente, wifi, descuentos en pagos, constancia de matrícula.

## 7. Publicar

Cuando las pruebas pasen:

1. Unir la rama de la app: `feat/backend-gateway` → `beta` (y luego `main`
   para la versión estable), con tu flujo de siempre de release.
2. Si muchos usuarios empiezan a usarla, deja una réplica siempre encendida
   para evitar la espera del primer arranque:

   ```bash
   cd /c/Users/aless/Desktop/dev/Auralix/nexo/nexo-backend
   MIN_REPLICAS=1 bash deploy/azure/deploy.sh
   ```

3. Cada cambio futuro del backend: commit y `bash deploy/azure/deploy.sh`.

## Después: Firebase App Check (solo la app oficial)

Hoy el backend corre con `APP_CHECK_MODE=monitor` porque la app aún no envía
el token. Para cerrarlo:

1. <https://console.firebase.google.com> → proyecto de Nexo → **App Check** →
   registrar la app Android con **Play Integrity**.
2. Anotar el *número de proyecto* y el *App ID* de Android.
3. Integrar `firebase_app_check` en la app (pendiente de programar).
4. En `.env.production`: `FIREBASE_PROJECT_NUMBER`, `FIREBASE_APP_IDS` y
   `APP_CHECK_MODE=enforce`; volver a ejecutar `bash deploy/azure/deploy.sh`.

## Costos

Con `MIN_REPLICAS=0` el contenedor se apaga sin tráfico y casi todo entra en
el crédito gratis mensual. El registro de imágenes (Basic) cuesta ~5 USD/mes del
crédito de Azure for Students. Puedes ver el gasto en el portal →
*Cost Management*.

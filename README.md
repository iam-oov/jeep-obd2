# Jeep OBD2

App Android en Flutter que lee y borra códigos de falla (DTC) con un adaptador ELM327 Bluetooth y busca videos de YouTube para repararlos.

Probada con un Jeep Wrangler TJ 1998 (ISO 9141-2) y un clon ELM327 Bluetooth clásico que no se empareja desde Ajustes.

## Funciones

- Conexión a ELM327 por Bluetooth clásico (socket RFCOMM sin emparejar) o Bluetooth LE.
- Lectura de códigos almacenados (modo 03) y pendientes (modo 07), con descripción en español.
- Borrado de códigos (modo 04) con confirmación.
- Lecturas en vivo: voltaje de batería, temperatura del refrigerante, RPM, velocidad y otras que el vehículo soporte.
- Varios vehículos guardados en el teléfono; lectura del VIN (modo 09) cuando el vehículo lo entrega.
- Búsqueda de videos de reparación con Claude Haiku y la YouTube Data API.
- Pantalla de log con los comandos enviados y las respuestas del adaptador.

## Instalar

Descarga el APK de [Releases](../../releases) e instálalo en Android 7 o posterior.

Para la búsqueda de videos, la app pide tus propias llaves (menú ⋮ → **Llaves de API**, o la primera vez que buscas un video):

- **Anthropic**: console.anthropic.com → API Keys.
- **YouTube**: Google Cloud → habilita YouTube Data API v3 → Credenciales → API key.

La app prueba las llaves antes de guardarlas y las guarda cifradas solo en tu teléfono (Android Keystore). El APK publicado no trae ninguna llave.

## Compilar

Requisitos: Flutter estable y Android SDK.

```
flutter build apk --release
```

El APK queda en `build/app/outputs/flutter-apk/app-release.apk`. Las llaves se capturan dentro de la app.

Opcional, solo para tu propio teléfono: copia `secrets.example.json` a `secrets.json`, pon tus llaves y compila con `--dart-define-from-file=secrets.json` para que la app ya las traiga. `secrets.json` está en `.gitignore`. Ese APK lleva tus llaves adentro: no lo publiques.

## Pruebas

```
flutter test
```

Las pruebas usan un ELM327 simulado (`test/fake_elm.dart`) y respuestas simuladas de Claude, YouTube y la NHTSA; no necesitan hardware ni llaves.

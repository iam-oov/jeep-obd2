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

Descarga el APK de [Releases](../../releases) e instálalo en Android 7 o posterior. El APK publicado no trae llaves de API: todo funciona salvo la búsqueda de videos.

## Compilar

Requisitos: Flutter estable y Android SDK.

1. Copia `secrets.example.json` a `secrets.json` y pon tus llaves:
   - `ANTHROPIC_API_KEY`: de console.anthropic.com.
   - `YOUTUBE_API_KEY`: de Google Cloud, con la YouTube Data API v3 habilitada.
2. Compila:

   ```
   flutter build apk --release --dart-define-from-file=secrets.json
   ```

3. Instala `build/app/outputs/flutter-apk/app-release.apk`.

`secrets.json` está en `.gitignore`. Las llaves quedan dentro del APK que compiles: no publiques ese APK.

## Pruebas

```
flutter test
```

Las pruebas usan un ELM327 simulado (`test/fake_elm.dart`) y respuestas simuladas de Claude, YouTube y la NHTSA; no necesitan hardware ni llaves.

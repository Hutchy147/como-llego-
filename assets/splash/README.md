Coloca este archivo PNG en esta carpeta antes de generar splash:

- `assets/splash/splash_logo.png`
  - Uso: logo de splash (Android y Android 12)
  - Tamaño recomendado: entre `512x512` y `1024x1024` px
  - Fondo: transparente
  - El color de fondo ya está configurado en blanco (`#FFFFFF`)

Luego ejecuta:

```bash
flutter pub get
dart run flutter_native_splash:create
```

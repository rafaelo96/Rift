# Protección estática compatible con transporte

Objetivo: conservar objetos que atraviesan un píxel aunque sus dos muestras sin compensar coincidan.
Alcance: Core/Interpolation, las cuatro rutas de síntesis luma/croma del mismo shader. Mantener oclusión suave, stack y archivo fuente.

- [x] Reproducir con punto trasladado 8 px y vector uniforme correcto: desaparece en t=0.25 con error máximo 896/1023.
- [x] Exigir coincidencia temporal también en las posiciones compensadas para justificar copia estática; mismos umbrales relativos existentes.
- [x] Comprobar t=0,0.25,0.5,0.75,1 y contenido idéntico con vectores espurios. Compilar shaders de luma/croma.
- [x] Comparar pares reales, medir costo en M4, documentar límites y commit del módulo. No afirmar que elimina motion blur ni equivale a Splash.

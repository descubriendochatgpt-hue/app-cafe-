#!/usr/bin/env bash
# Junta todas las migraciones en un solo fichero, en orden, para pegarlo de
# una vez en el editor SQL de Supabase.
#
# No sustituye a `supabase db push`: es el camino para quien no quiere
# instalar el CLI. Sale de las mismas migraciones, así que no hay dos
# versiones del esquema que puedan separarse.
set -euo pipefail
cd "$(dirname "$0")"
salida="esquema-completo.sql"

{
  echo "-- ═══════════════════════════════════════════════════════════════════"
  echo "--  ESQUEMA COMPLETO · generado por generar-esquema.sh, no editar"
  echo "--"
  echo "--  Pégalo entero en Supabase → SQL Editor y dale a Run. Crea las"
  echo "--  tablas, las políticas RLS, las funciones y un administrador con"
  echo "--  PIN 1234 que hay que cambiar antes de usarlo de verdad."
  echo "--"
  echo "--  Se puede volver a ejecutar sobre una base ya creada: fallará al"
  echo "--  llegar a la primera tabla que ya exista, y no habrá tocado nada,"
  echo "--  porque el editor de Supabase lo ejecuta todo en una transacción."
  echo "-- ═══════════════════════════════════════════════════════════════════"
  echo
  for f in migrations/*.sql; do
    echo
    echo "-- ╔══ $(basename "$f") ══╗"
    echo
    cat "$f"
  done
} > "$salida"

echo "✓ $salida · $(wc -l < "$salida") líneas, $(du -h "$salida" | cut -f1)"

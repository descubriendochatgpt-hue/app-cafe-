import type { NextConfig } from 'next';

const config: NextConfig = {
  reactStrictMode: true,
  // La clave de servicio no puede acabar nunca en el paquete del navegador.
  // Todo el acceso a datos pasa por rutas de servidor.
  serverExternalPackages: ['@supabase/supabase-js'],
};

export default config;

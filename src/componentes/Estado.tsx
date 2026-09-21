'use client';

/**
 * Estado compartido de la aplicación: el catálogo descargado, cuántas
 * operaciones quedan sin subir y si hay red.
 *
 * La sincronización se dispara sola en tres momentos: al arrancar, al
 * recuperar la conexión y cada minuto. El operario nunca tiene que acordarse
 * de pulsar nada para que suba lo del mercado.
 */
import {
  createContext, useContext, useEffect, useState, useCallback, type ReactNode,
} from 'react';
import {
  guardarCatalogo, leerCatalogo, cuantasPendientes, bloqueadas,
  type Catalogo, type LoteDetalle, type SaldoDetalle, type EnCola,
} from '@/lib/almacenLocal';
import { sincronizar } from '@/lib/sincronizacion';

interface Valor {
  catalogo: Catalogo | null;
  cargando: boolean;
  enCola: number;
  atascadas: EnCola[];
  conectado: boolean;
  refrescar: () => Promise<void>;
  subir: () => Promise<void>;
  lote: (loteId: string) => LoteDetalle | undefined;
  saldoDe: (loteId: string, ubicacion: string) => SaldoDetalle | undefined;
}

const Contexto = createContext<Valor | null>(null);

export function useApp(): Valor {
  const v = useContext(Contexto);
  if (!v) throw new Error('useApp fuera del proveedor de estado');
  return v;
}

export function ProveedorEstado({ children }: { children: ReactNode }) {
  const [catalogo, setCatalogo] = useState<Catalogo | null>(null);
  const [cargando, setCargando] = useState(true);
  const [enCola, setEnCola] = useState(0);
  const [atascadas, setAtascadas] = useState<EnCola[]>([]);
  const [conectado, setConectado] = useState(true);

  const contarCola = useCallback(async () => {
    setEnCola(await cuantasPendientes());
    setAtascadas(await bloqueadas());
  }, []);

  const refrescar = useCallback(async () => {
    try {
      const r = await fetch('/api/catalogo');
      if (!r.ok) return;                       // sin red o sin sesión: nos quedamos con la copia
      const datos = (await r.json()) as Catalogo;
      await guardarCatalogo(datos);
      setCatalogo(datos);
    } catch {
      // Offline. La copia local sigue sirviendo, que es justo para lo que está.
    }
  }, []);

  const subir = useCallback(async () => {
    // Subir la cola y refrescar el catálogo son dos cosas independientes, y
    // antes iban atadas: si subir fallaba —una venta rechazada, un corte a
    // mitad—, la excepción se llevaba por delante el refresco, y el catálogo
    // se quedaba congelado hasta recargar la página. Justo al revés de lo que
    // conviene: cuando algo va mal es cuando más falta hace ver el dato bueno.
    try {
      await sincronizar();
    } catch {
      // Lo que no suba se queda en la cola y se reintenta solo.
    }
    await contarCola();
    await refrescar();
  }, [contarCola, refrescar]);

  useEffect(() => {
    let vivo = true;

    // Primero lo local, para que la app abra al instante aunque no haya red.
    void (async () => {
      const guardado = await leerCatalogo();
      if (vivo && guardado) setCatalogo(guardado);
      await contarCola();
      await refrescar();
      if (vivo) setCargando(false);
      await subir();
    })();

    const alConectar = () => { setConectado(true); void subir(); };
    const alDesconectar = () => setConectado(false);
    setConectado(navigator.onLine);

    window.addEventListener('online', alConectar);
    window.addEventListener('offline', alDesconectar);
    const reloj = setInterval(() => { void subir(); }, 60_000);

    return () => {
      vivo = false;
      window.removeEventListener('online', alConectar);
      window.removeEventListener('offline', alDesconectar);
      clearInterval(reloj);
    };
  }, [contarCola, refrescar, subir]);

  const lote = useCallback(
    (loteId: string) => catalogo?.lotes.find((l) => l.lote_id === loteId),
    [catalogo],
  );

  const saldoDe = useCallback(
    (loteId: string, ubicacion: string) =>
      catalogo?.saldos.find((s) => s.lote_id === loteId && s.ubicacion_id === ubicacion),
    [catalogo],
  );

  return (
    <Contexto.Provider
      value={{ catalogo, cargando, enCola, atascadas, conectado, refrescar, subir, lote, saldoDe }}
    >
      {children}
    </Contexto.Provider>
  );
}

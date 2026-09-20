import { describe, it, expect } from 'vitest';
import { SignJWT } from 'jose';
import { firmarToken, leerToken, alcanza } from '../jwt';
import type { Sesion } from '../tipos';

const SECRETO = 'un-secreto-de-pruebas-suficientemente-largo-123456';
const OTRO    = 'otro-secreto-de-pruebas-igual-de-largo-0987654321';

const operario: Sesion = {
  usuarioId: '11111111-1111-4111-8111-111111111111',
  nombre: 'Marta',
  rol: 'OPERARIO',
};

describe('token de sesión', () => {
  it('conserva quién eres al ir y volver', async () => {
    const leido = await leerToken(await firmarToken(operario, SECRETO, 12), SECRETO);
    expect(leido).toEqual(operario);
  });

  it('rechaza un token firmado con otro secreto', async () => {
    const ajeno = await firmarToken({ ...operario, rol: 'ADMIN' }, OTRO, 12);
    expect(await leerToken(ajeno, SECRETO)).toBeNull();
  });

  it('rechaza un token caducado', async () => {
    const caducado = await new SignJWT({ rol: 'ADMIN', nombre: 'X', role: 'authenticated' })
      .setProtectedHeader({ alg: 'HS256' })
      .setSubject(operario.usuarioId)
      .setIssuedAt(Math.floor(Date.now() / 1000) - 7200)
      .setExpirationTime(Math.floor(Date.now() / 1000) - 3600)
      .sign(new TextEncoder().encode(SECRETO));
    expect(await leerToken(caducado, SECRETO)).toBeNull();
  });

  it('rechaza un token sin algoritmo de firma', async () => {
    // El ataque clásico: alg "none" para colarse sin firmar.
    const cabecera = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
    const cuerpo = Buffer.from(JSON.stringify({ sub: operario.usuarioId, rol: 'ADMIN' })).toString('base64url');
    expect(await leerToken(`${cabecera}.${cuerpo}.`, SECRETO)).toBeNull();
  });

  it('rechaza un rol que no existe', async () => {
    const inventado = await new SignJWT({ rol: 'SUPERJEFE', role: 'authenticated' })
      .setProtectedHeader({ alg: 'HS256' })
      .setSubject(operario.usuarioId)
      .setExpirationTime('1h')
      .sign(new TextEncoder().encode(SECRETO));
    expect(await leerToken(inventado, SECRETO)).toBeNull();
  });

  it('rechaza un token manipulado en el cuerpo', async () => {
    const bueno = await firmarToken(operario, SECRETO, 12);
    const [c, , f] = bueno.split('.');
    const cuerpoFalso = Buffer.from(
      JSON.stringify({ sub: operario.usuarioId, rol: 'ADMIN', exp: 9999999999 }),
    ).toString('base64url');
    expect(await leerToken(`${c}.${cuerpoFalso}.${f}`, SECRETO)).toBeNull();
  });
});

describe('jerarquía de permisos', () => {
  it('coincide con app.nivel() de Postgres', () => {
    expect(alcanza('OPERARIO', 'OPERARIO')).toBe(true);
    expect(alcanza('OPERARIO', 'GESTOR')).toBe(false);
    expect(alcanza('GESTOR', 'OPERARIO')).toBe(true);
    expect(alcanza('ADMIN', 'GESTOR')).toBe(true);
    expect(alcanza('SISTEMA', 'ADMIN')).toBe(true);
  });
});

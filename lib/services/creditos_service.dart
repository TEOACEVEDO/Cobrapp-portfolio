import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/credito_model.dart';
import 'cuotas_service.dart';
import 'storage_service.dart';

class CreditosService {
  final supabase = Supabase.instance.client;

  // ============================================================
  // DINERO SIEMPRE EN PESOS ENTEROS
  // ============================================================

  double pesosEnteros(double valor) {
    return valor.round().toDouble();
  }

  // ============================================================
  // CREAR CRÉDITO
  // ============================================================

Future<void> crearCredito({
  required String clienteId,
  required double valorCredito,
  required double interes,
  required int numeroCuotas,
  required DateTime fechaInicio,
  required String frecuencia,
  required double valorMora,
  required int diasAplazamiento,
  required double valorAdelanto,
  required DateTime fechaHabitual,
}) async {
  final valorCreditoEntero = pesosEnteros(valorCredito);
  final valorMoraEntero = pesosEnteros(valorMora);
  final valorAdelantoEntero = pesosEnteros(valorAdelanto);

  // Generar las cuotas en Flutter conservando
  // el cálculo actual de capital, interés y fechas.
  final cuotas = CuotasService().generarCuotas(
    valorPrestamo: valorCreditoEntero,
    interes: interes,
    numeroCuotas: numeroCuotas,
    primerPago: fechaInicio,
    frecuencia: frecuencia,
  );

  if (cuotas.length != numeroCuotas) {
    throw Exception(
      'No fue posible generar todas las cuotas del crédito.',
    );
  }

  // Preparar los datos que PostgreSQL recibirá
  // para guardar dentro de una única transacción.
  final datosCuotas = cuotas.map((cuota) {
    final fecha = cuota.fechaVencimiento;

    return {
      'numero_cuota': cuota.numero,
      'capital': pesosEnteros(cuota.capital),
      'capital_pendiente': pesosEnteros(
        cuota.capitalPendiente,
      ),
      'interes': pesosEnteros(cuota.interes),
      'interes_pendiente': pesosEnteros(
        cuota.interesPendiente,
      ),
      'mora': pesosEnteros(cuota.mora),
      'mora_pendiente': pesosEnteros(
        cuota.moraPendiente,
      ),
      'valor_cuota': pesosEnteros(cuota.valorCuota),
      'saldo_pendiente': pesosEnteros(
        cuota.saldoPendiente,
      ),
      'total_pagado': pesosEnteros(cuota.totalPagado),
      'fecha_vencimiento':
          '${fecha.year.toString().padLeft(4, '0')}-'
          '${fecha.month.toString().padLeft(2, '0')}-'
          '${fecha.day.toString().padLeft(2, '0')}',
      'estado': cuota.estado,
    };
  }).toList();

  final fechaInicioTexto =
      '${fechaInicio.year.toString().padLeft(4, '0')}-'
      '${fechaInicio.month.toString().padLeft(2, '0')}-'
      '${fechaInicio.day.toString().padLeft(2, '0')}';

  final fechaHabitualTexto =
      '${fechaHabitual.year.toString().padLeft(4, '0')}-'
      '${fechaHabitual.month.toString().padLeft(2, '0')}-'
      '${fechaHabitual.day.toString().padLeft(2, '0')}';

  // Una sola llamada a PostgreSQL:
  // crédito + cuotas + cargo, si corresponde.
  await supabase.rpc(
    'crear_credito_transaccional',
    params: {
      'p_cliente_id': clienteId,
      'p_valor_credito': valorCreditoEntero,
      'p_interes': interes,
      'p_numero_cuotas': numeroCuotas,
      'p_fecha_inicio': fechaInicioTexto,
      'p_frecuencia': frecuencia,
      'p_valor_mora': valorMoraEntero,
      'p_cuotas': datosCuotas,
      'p_dias_aplazamiento': diasAplazamiento,
      'p_valor_adelanto': valorAdelantoEntero,
      'p_fecha_habitual': fechaHabitualTexto,
    },
  );
}

  // ============================================================
  // OBTENER CRÉDITOS POR CLIENTE
  // ============================================================

  Future<List<CreditoModel>> obtenerCreditosPorCliente(String clienteId) async {
    final response = await supabase
        .from('creditos')
        .select()
        .eq('cliente_id', clienteId)
        .order('created_at', ascending: false);

    return response
        .map<CreditoModel>((map) => CreditoModel.fromMap(map))
        .toList();
  }

  // ============================================================
  // OBTENER CRÉDITO POR ID
  // ============================================================

  Future<CreditoModel> obtenerCreditoPorId(String id) async {
    final response = await supabase
        .from('creditos')
        .select()
        .eq('id', id)
        .single();

    return CreditoModel.fromMap(response);
  }

  // ============================================================
  // SABER SI UN CRÉDITO TIENE PAGOS
  // ============================================================

  Future<bool> creditoTienePagos(String creditoId) async {
    final cuotasResponse = await supabase
        .from('cuotas')
        .select('id')
        .eq('credito_id', creditoId);

    final cuotas = List<Map<String, dynamic>>.from(cuotasResponse);

    if (cuotas.isEmpty) {
      return false;
    }

    final cuotaIds = cuotas.map((cuota) => cuota['id'] as String).toList();

    final pagosResponse = await supabase
        .from('pagos')
        .select('id')
        .inFilter('cuota_id', cuotaIds)
        .limit(1);

    return pagosResponse.isNotEmpty;
  }

  // ============================================================
  // ACTUALIZAR CRÉDITO
  // ============================================================

  Future<void> actualizarCredito({
    required String creditoId,
    required double valorCredito,
    required double interes,
    required int numeroCuotas,
    required DateTime fechaInicio,
    required String frecuencia,
    required double valorMora,
  }) async {
    final valorCreditoEntero = pesosEnteros(valorCredito);

    final valorMoraEntero = pesosEnteros(valorMora);

    await supabase
        .from('creditos')
        .update({
          'valor_credito': valorCreditoEntero,
          'interes': interes,
          'numero_cuotas': numeroCuotas,
          'fecha_inicio': fechaInicio.toIso8601String(),
          'frecuencia': frecuencia,
          'valor_mora': valorMoraEntero,
        })
        .eq('id', creditoId);
  }

  // ============================================================
  // REGENERAR CUOTAS
  // ============================================================

  Future<void> regenerarCuotas({
    required String creditoId,
    required double valorCredito,
    required double interes,
    required int numeroCuotas,
    required DateTime fechaInicio,
    required String frecuencia,
    required double valorMora,
  }) async {
    final valorCreditoEntero = pesosEnteros(valorCredito);

    // Normalizamos la mora aunque actualmente
    // no intervenga en la generación de cuotas.
    final valorMoraEntero = pesosEnteros(valorMora);

    // ============================================================
    // 1. ACTUALIZAR VALOR DE MORA DEL CRÉDITO
    // ============================================================

    await supabase
        .from('creditos')
        .update({'valor_mora': valorMoraEntero})
        .eq('id', creditoId);

    // ============================================================
    // 2. ELIMINAR CUOTAS ACTUALES
    // ============================================================

    await supabase.from('cuotas').delete().eq('credito_id', creditoId);

    // ============================================================
    // 3. GENERAR NUEVAS CUOTAS
    // ============================================================

    final cuotas = CuotasService().generarCuotas(
      valorPrestamo: valorCreditoEntero,
      interes: interes,
      numeroCuotas: numeroCuotas,
      primerPago: fechaInicio,
      frecuencia: frecuencia,
    );

    // ============================================================
    // 4. PREPARAR DATOS
    // ============================================================

    final datosCuotas = cuotas.map((cuota) {
      return {
        'credito_id': creditoId,
        'numero_cuota': cuota.numero,
        'capital': cuota.capital,
        'capital_pendiente': cuota.capitalPendiente,
        'interes': cuota.interes,
        'interes_pendiente': cuota.interesPendiente,
        'mora': cuota.mora,
        'mora_pendiente': cuota.moraPendiente,
        'valor_cuota': cuota.valorCuota,
        'saldo_pendiente': cuota.saldoPendiente,
        'total_pagado': cuota.totalPagado,
        'fecha_vencimiento': cuota.fechaVencimiento.toIso8601String(),
        'estado': cuota.estado,
      };
    }).toList();

    // ============================================================
    // 5. GUARDAR NUEVAS CUOTAS
    // ============================================================

    await supabase.from('cuotas').insert(datosCuotas);
  }

  // ============================================================
  // ELIMINAR CRÉDITO
  // ============================================================

Future<void> eliminarCredito(String creditoId) async {
  // 1. Eliminar primero el crédito y sus registros en Supabase.
  // Si esto falla, la ejecución se detiene y los archivos se conservan.
  await supabase.rpc(
    'eliminar_credito_transaccional',
    params: {
      'p_credito_id': creditoId,
    },
  );

  // 2. Si la base de datos confirmó la eliminación,
  // eliminar los comprobantes almacenados.
  try {
    await StorageService().eliminarComprobantesDeCredito(
      creditoId,
    );
  } catch (e) {
    // El crédito ya se eliminó, pero puede quedar algún archivo.
    throw Exception(
      'El crédito se eliminó correctamente, pero no se pudieron '
      'eliminar todos sus comprobantes. Puedes reintentar la '
      'limpieza de archivos. Detalle: $e',
    );
  }
}

}

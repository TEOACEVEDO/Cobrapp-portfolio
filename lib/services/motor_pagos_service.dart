import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/cuota_model.dart';
import '../models/pago_model.dart';
import '../models/resultado_pago_model.dart';

import 'pagos_service.dart';

class MotorPagosService {
  final supabase = Supabase.instance.client;

  final pagosService = PagosService();

  // ============================================================
  // DINERO SIEMPRE EN PESOS ENTEROS
  // ============================================================

  double pesosEnteros(double valor) {
    return valor.round().toDouble();
  }

  // ============================================================
  // OBTENER VALOR DE MORA DIARIA DEL CRÉDITO
  // ============================================================

  Future<double> obtenerValorMoraDiaria(String creditoId) async {
    final response = await supabase
        .from('creditos')
        .select('valor_mora')
        .eq('id', creditoId)
        .single();

    final valor = response['valor_mora'];

    if (valor == null) {
      return 0;
    }

    if (valor is num) {
      return pesosEnteros(valor.toDouble());
    }

    final convertido = double.tryParse(valor.toString()) ?? 0;

    return pesosEnteros(convertido);
  }

  // ============================================================
  // CALCULAR DÍAS DE MORA
  // ============================================================

  int obtenerDiasMora(DateTime fechaVencimiento) {
    final hoy = DateTime.now();

    final fechaVencimientoSinHora = DateTime(
      fechaVencimiento.year,
      fechaVencimiento.month,
      fechaVencimiento.day,
    );

    final fechaHoySinHora = DateTime(
      hoy.year,
      hoy.month,
      hoy.day,
    );

    if (!fechaHoySinHora.isAfter(fechaVencimientoSinHora)) {
      return 0;
    }

    return fechaHoySinHora
        .difference(fechaVencimientoSinHora)
        .inDays;
  }

  // ============================================================
  // CALCULAR MORA AUTOMÁTICA
  // ============================================================

  double calcularMoraAutomatica({
    required CuotaModel cuota,
    required double valorMoraDiaria,
    required double capitalPendiente,
    required double interesPendiente,
  }) {
    final moraActual = pesosEnteros(cuota.mora);

    // ------------------------------------------------------------
    // Si capital e interés ya están completamente pagados,
    // la mora queda congelada.
    // ------------------------------------------------------------

    if (capitalPendiente <= 0 && interesPendiente <= 0) {
      return moraActual;
    }

    // ------------------------------------------------------------
    // Sin mora diaria configurada no se genera mora nueva.
    // ------------------------------------------------------------

    if (valorMoraDiaria <= 0) {
      return moraActual;
    }

    final diasMora = obtenerDiasMora(
      cuota.fechaVencimiento,
    );

    if (diasMora <= 0) {
      return moraActual;
    }

    // ------------------------------------------------------------
    // Mora generada
    // ------------------------------------------------------------

    final moraCalculada = pesosEnteros(
      diasMora * pesosEnteros(valorMoraDiaria),
    );

    // Nunca reducimos una mora que ya existe.
    if (moraCalculada > moraActual) {
      return moraCalculada;
    }

    return moraActual;
  }

  // ============================================================
  // OBTENER PRIMERA CUOTA PENDIENTE
  // ============================================================

  Future<CuotaModel?> obtenerPrimeraCuotaPendiente(
    String creditoId,
  ) async {
    final response = await supabase
        .from('cuotas')
        .select()
        .eq('credito_id', creditoId)
        .neq('estado', 'pagada')
        .order('numero_cuota', ascending: true)
        .limit(1);

    if (response.isEmpty) {
      return null;
    }

    return CuotaModel.fromMap(response.first);
  }

  // ============================================================
  // OBTENER TODAS LAS CUOTAS DEL CRÉDITO
  // ============================================================

  Future<List<CuotaModel>> obtenerCuotasCredito(
    String creditoId,
  ) async {
    final response = await supabase
        .from('cuotas')
        .select()
        .eq('credito_id', creditoId)
        .order('numero_cuota', ascending: true);

    return response
        .map<CuotaModel>(
          (map) => CuotaModel.fromMap(map),
        )
        .toList();
  }

  // ============================================================
  // APLICAR PAGO NORMAL A UNA CUOTA
  //
  // ORDEN:
  // CAPITAL → INTERÉS → MORA
  // ============================================================

  Future<ResultadoPagoModel> aplicarPagoACuota({
    required CuotaModel cuota,
    required PagoModel pago,
    required String nombreCliente,
    required double valorMoraDiaria,
  }) async {
    double restante = pesosEnteros(
      pago.valorPagado,
    );

    final valorOriginal = restante;

    double capitalPendiente = pesosEnteros(
      cuota.capitalPendiente,
    );

    double interesPendiente = pesosEnteros(
      cuota.interesPendiente,
    );

    double moraPendiente = pesosEnteros(
      cuota.moraPendiente,
    );

    // ============================================================
    // ACTUALIZAR MORA AUTOMÁTICAMENTE
    // ============================================================

    final nuevaMoraTotal = calcularMoraAutomatica(
      cuota: cuota,
      valorMoraDiaria: valorMoraDiaria,
      capitalPendiente: capitalPendiente,
      interesPendiente: interesPendiente,
    );

    // ============================================================
    // CALCULAR MORA YA PAGADA
    // ============================================================

    final moraActual = pesosEnteros(
      cuota.mora,
    );

    final moraYaPagada = pesosEnteros(
      moraActual - moraPendiente,
    );

    moraPendiente = pesosEnteros(
      nuevaMoraTotal - moraYaPagada,
    );

    if (moraPendiente < 0) {
      moraPendiente = 0;
    }

    // ============================================================
    // VARIABLES DEL PAGO
    // ============================================================

    double capitalPagado = 0;
    double interesPagado = 0;
    double moraPagada = 0;

    // ============================================================
    // CAPITAL
    // ============================================================

    if (restante > 0 && capitalPendiente > 0) {
      final abono = restante >= capitalPendiente
          ? capitalPendiente
          : restante;

      capitalPendiente = pesosEnteros(
        capitalPendiente - abono,
      );

      restante = pesosEnteros(
        restante - abono,
      );

      capitalPagado = pesosEnteros(
        abono,
      );
    }

    // ============================================================
    // INTERÉS
    // ============================================================

    if (restante > 0 && interesPendiente > 0) {
      final abono = restante >= interesPendiente
          ? interesPendiente
          : restante;

      interesPendiente = pesosEnteros(
        interesPendiente - abono,
      );

      restante = pesosEnteros(
        restante - abono,
      );

      interesPagado = pesosEnteros(
        abono,
      );
    }

    // ============================================================
    // MORA
    // ============================================================

    if (restante > 0 && moraPendiente > 0) {
      final abono = restante >= moraPendiente
          ? moraPendiente
          : restante;

      moraPendiente = pesosEnteros(
        moraPendiente - abono,
      );

      restante = pesosEnteros(
        restante - abono,
      );

      moraPagada = pesosEnteros(
        abono,
      );
    }

    // ============================================================
    // VALOR APLICADO
    // ============================================================

    final valorAplicado = pesosEnteros(
      valorOriginal - restante,
    );

    // ============================================================
    // SALDO PENDIENTE
    // ============================================================

    final saldoPendiente = pesosEnteros(
      capitalPendiente +
          interesPendiente +
          moraPendiente,
    );

    // ============================================================
    // TOTAL PAGADO
    // ============================================================

    final totalPagado = pesosEnteros(
      cuota.totalPagado +
          valorAplicado,
    );

    // ============================================================
    // ESTADO
    // ============================================================

    final estado = saldoPendiente == 0
        ? 'pagada'
        : 'pendiente';

    // ============================================================
    // CUOTA ACTUALIZADA
    // ============================================================

    final cuotaActualizada = CuotaModel(
      id: cuota.id,
      creditoId: cuota.creditoId,
      numero: cuota.numero,

      capital: pesosEnteros(
        cuota.capital,
      ),

      capitalPendiente: capitalPendiente,

      interes: pesosEnteros(
        cuota.interes,
      ),

      interesPendiente: interesPendiente,

      mora: nuevaMoraTotal,

      moraPendiente: moraPendiente,

      valorCuota: pesosEnteros(
        cuota.valorCuota,
      ),

      saldoPendiente: saldoPendiente,

      totalPagado: totalPagado,

      fechaVencimiento: cuota.fechaVencimiento,

      estado: estado,

      createdAt: cuota.createdAt,
    );

    // ============================================================
    // ACTUALIZAR CUOTA
    // ============================================================

    await supabase
        .from('cuotas')
        .update(
          cuotaActualizada.toUpdateMap(),
        )
        .eq(
          'id',
          cuota.id,
        );

    // ============================================================
    // REGISTRAR PAGO
    // ============================================================

    if (valorAplicado > 0) {
      await pagosService.registrarPago(
        pago: PagoModel(
          cuotaId: cuota.id,

          valorPagado: valorAplicado,

          capitalPagado: capitalPagado,

          interesPagado: interesPagado,

          moraPagada: moraPagada,

          tipoPago: 'normal',

          metodoPago: pago.metodoPago,

          comprobanteUrl: pago.comprobanteUrl,

          entidad: pago.entidad,

          observaciones: pago.observaciones,

          fechaPago: pago.fechaPago,
        ),
        nombreCliente: nombreCliente,
        numeroCuota: cuota.numero,
      );
    }

    return ResultadoPagoModel(
      aplicado: valorAplicado,
      restante: restante,
    );
  }

  // ============================================================
  // PROCESAR PAGO NORMAL
  // ============================================================

  Future<void> procesarPago({
    required String creditoId,
    required PagoModel pago,
    required String nombreCliente,
  }) async {
    double restante = pesosEnteros(
      pago.valorPagado,
    );

    final valorMoraDiaria =
        await obtenerValorMoraDiaria(
      creditoId,
    );

    while (restante > 0) {
      final cuota =
          await obtenerPrimeraCuotaPendiente(
        creditoId,
      );

      if (cuota == null) {
        break;
      }

      final resultado =
          await aplicarPagoACuota(
        cuota: cuota,

        pago: PagoModel(
          cuotaId: cuota.id,

          valorPagado: restante,

          metodoPago: pago.metodoPago,

          comprobanteUrl: pago.comprobanteUrl,

          entidad: pago.entidad,

          moraPagada: pago.moraPagada,

          observaciones: pago.observaciones,

          fechaPago: pago.fechaPago,
        ),

        nombreCliente: nombreCliente,

        valorMoraDiaria: valorMoraDiaria,
      );

      restante = pesosEnteros(
        resultado.restante,
      );
    }
  }

  // ============================================================
  // PAGO EXCLUSIVO A CAPITAL + INTERÉS
  //
  // ORDEN:
  // CAPITAL → INTERÉS
  //
  // NUNCA PAGA MORA
  // ============================================================

  Future<void> procesarPagoCapitalInteres({
  required String creditoId,
  required PagoModel pago,
  required String nombreCliente,
  required CuotaModel cuota,
}) async {
  double restante = pesosEnteros(
    pago.valorPagado,
  );

  if (restante <= 0) {
    throw Exception(
      'El valor del pago debe ser mayor que cero.',
    );
  }

  // ============================================================
  // OBTENER MORA DIARIA
  // ============================================================

  final valorMoraDiaria =
      await obtenerValorMoraDiaria(
    creditoId,
  );

  // ============================================================
  // OBTENER CUOTAS DESDE LA CUOTA SELECCIONADA
  //
  // El dinero avanza hacia las cuotas siguientes.
  // ============================================================

  final todasLasCuotas =
      await obtenerCuotasCredito(
    creditoId,
  );

  final cuotasPendientes =
      todasLasCuotas.where((c) {
    return c.numero >= cuota.numero &&
        c.estado != 'pagada';
  }).toList();

  if (cuotasPendientes.isEmpty) {
    throw Exception(
      'No existen cuotas pendientes para aplicar el pago.',
    );
  }

  // ============================================================
  // CALCULAR CUÁNTO CAPITAL + INTERÉS EXISTE EN TOTAL
  //
  // Esto NO incluye mora.
  //
  // Es el único límite real del pago.
  // ============================================================

  double totalCapitalInteresDisponible = 0;

  for (final cuotaPendiente in cuotasPendientes) {
    totalCapitalInteresDisponible +=
        pesosEnteros(
          cuotaPendiente.capitalPendiente,
        );

    totalCapitalInteresDisponible +=
        pesosEnteros(
          cuotaPendiente.interesPendiente,
        );
  }

  totalCapitalInteresDisponible =
      pesosEnteros(
    totalCapitalInteresDisponible,
  );

  // ============================================================
  // SI INTENTA PAGAR MÁS QUE TODO EL CAPITAL + INTERÉS
  // DEL RESTO DEL CRÉDITO, NO TENEMOS DÓNDE APLICARLO
  // SIN TOCAR MORA.
  // ============================================================

  if (restante > totalCapitalInteresDisponible) {
    throw Exception(
      'El valor ingresado supera el total pendiente de '
      'capital e intereses de las cuotas restantes: '
      '\$${totalCapitalInteresDisponible.toStringAsFixed(0)}. '
      'La mora no se puede pagar con este botón.',
    );
  }

  // ============================================================
  // RECORRER CUOTAS
  // ============================================================

  for (final cuotaActual in cuotasPendientes) {
    if (restante <= 0) {
      break;
    }

    // ==========================================================
    // DATOS PENDIENTES
    // ==========================================================

    double capitalPendiente =
        pesosEnteros(
      cuotaActual.capitalPendiente,
    );

    double interesPendiente =
        pesosEnteros(
      cuotaActual.interesPendiente,
    );

    // ==========================================================
    // ACTUALIZAR MORA DE ESTA CUOTA
    //
    // Importante:
    // aquí NO pagamos la mora.
    //
    // Solamente calculamos cuánto existe.
    // ==========================================================

    final nuevaMoraTotal =
        calcularMoraAutomatica(
      cuota: cuotaActual,
      valorMoraDiaria: valorMoraDiaria,
      capitalPendiente: capitalPendiente,
      interesPendiente: interesPendiente,
    );

    final moraActual =
        pesosEnteros(
      cuotaActual.mora,
    );

    final moraPendienteActual =
        pesosEnteros(
      cuotaActual.moraPendiente,
    );

    final moraYaPagada =
        pesosEnteros(
      moraActual -
          moraPendienteActual,
    );

    double moraPendiente =
        pesosEnteros(
      nuevaMoraTotal -
          moraYaPagada,
    );

    if (moraPendiente < 0) {
      moraPendiente = 0;
    }

    // ==========================================================
    // SI ESTA CUOTA SOLO TIENE MORA
    //
    // No tocamos nada y continuamos con la siguiente.
    // ==========================================================

    if (capitalPendiente <= 0 &&
        interesPendiente <= 0) {
      continue;
    }

    // ==========================================================
    // VARIABLES DEL PAGO
    // ==========================================================

    double capitalPagado = 0;
    double interesPagado = 0;

    final valorAntesDeAplicar =
        restante;

    // ==========================================================
    // CAPITAL
    // ==========================================================

    if (restante > 0 &&
        capitalPendiente > 0) {
      final abono = restante >= capitalPendiente
          ? capitalPendiente
          : restante;

      capitalPendiente =
          pesosEnteros(
        capitalPendiente -
            abono,
      );

      restante =
          pesosEnteros(
        restante -
            abono,
      );

      capitalPagado =
          pesosEnteros(
        abono,
      );
    }

    // ==========================================================
    // INTERÉS
    // ==========================================================

    if (restante > 0 &&
        interesPendiente > 0) {
      final abono = restante >= interesPendiente
          ? interesPendiente
          : restante;

      interesPendiente =
          pesosEnteros(
        interesPendiente -
            abono,
      );

      restante =
          pesosEnteros(
        restante -
            abono,
      );

      interesPagado =
          pesosEnteros(
        abono,
      );
    }

    // ==========================================================
    // NUNCA TOCAR MORA
    // ==========================================================

    const double moraPagada = 0;

    // ==========================================================
    // VALOR APLICADO A ESTA CUOTA
    // ==========================================================

    final valorAplicado =
        pesosEnteros(
      valorAntesDeAplicar -
          restante,
    );

    if (valorAplicado <= 0) {
      continue;
    }

    // ==========================================================
    // SALDO PENDIENTE
    //
    // Incluye la mora, pero NO la estamos pagando.
    // ==========================================================

    final saldoPendiente =
        pesosEnteros(
      capitalPendiente +
          interesPendiente +
          moraPendiente,
    );

    // ==========================================================
    // TOTAL PAGADO
    // ==========================================================

    final totalPagado =
        pesosEnteros(
      cuotaActual.totalPagado +
          valorAplicado,
    );

    // ==========================================================
    // ESTADO
    // ==========================================================

    final estado =
        saldoPendiente == 0
            ? 'pagada'
            : 'pendiente';

    // ==========================================================
    // ACTUALIZAR CUOTA
    // ==========================================================

    final cuotaActualizada =
        CuotaModel(
      id: cuotaActual.id,

      creditoId:
          cuotaActual.creditoId,

      numero:
          cuotaActual.numero,

      capital:
          pesosEnteros(
        cuotaActual.capital,
      ),

      capitalPendiente:
          capitalPendiente,

      interes:
          pesosEnteros(
        cuotaActual.interes,
      ),

      interesPendiente:
          interesPendiente,

      mora:
          nuevaMoraTotal,

      moraPendiente:
          moraPendiente,

      valorCuota:
          pesosEnteros(
        cuotaActual.valorCuota,
      ),

      saldoPendiente:
          saldoPendiente,

      totalPagado:
          totalPagado,

      fechaVencimiento:
          cuotaActual.fechaVencimiento,

      estado:
          estado,

      createdAt:
          cuotaActual.createdAt,
    );

    // ==========================================================
    // GUARDAR CUOTA
    // ==========================================================

    await supabase
        .from('cuotas')
        .update(
          cuotaActualizada.toUpdateMap(),
        )
        .eq(
          'id',
          cuotaActual.id,
        );

    // ==========================================================
    // REGISTRAR PAGO
    //
    // Cada cuota recibe su propio registro.
    // ==========================================================

    await pagosService.registrarPago(
      pago: PagoModel(
        cuotaId:
            cuotaActual.id,

        valorPagado:
            valorAplicado,

        capitalPagado:
            capitalPagado,

        interesPagado:
            interesPagado,

        moraPagada:
            moraPagada,

        tipoPago:
            'capital_interes',

        metodoPago:
            pago.metodoPago,

        comprobanteUrl:
            pago.comprobanteUrl,

        entidad:
            pago.entidad,

        observaciones:
            pago.observaciones,

        fechaPago:
            pago.fechaPago,
      ),

      nombreCliente:
          nombreCliente,

      numeroCuota:
          cuotaActual.numero,
    );
  }
}
  // ============================================================
  // OBTENER MORAS ACUMULADAS
  //
  // Devuelve las cuotas que tienen mora pendiente.
  // ============================================================

  Future<List<CuotaModel>> obtenerCuotasConMoraPendiente(
  String creditoId,
) async {
  final cuotas = await obtenerCuotasCredito(
    creditoId,
  );

  final valorMoraDiaria = await obtenerValorMoraDiaria(
    creditoId,
  );

  final cuotasConMora = <CuotaModel>[];

  for (final cuota in cuotas) {
    final capitalPendiente = pesosEnteros(
      cuota.capitalPendiente,
    );

    final interesPendiente = pesosEnteros(
      cuota.interesPendiente,
    );

    // ==========================================================
    // CALCULAR LA MORA ACTUAL DE LA CUOTA
    // ==========================================================

    final moraTotal = calcularMoraAutomatica(
      cuota: cuota,
      valorMoraDiaria: valorMoraDiaria,
      capitalPendiente: capitalPendiente,
      interesPendiente: interesPendiente,
    );

    // ==========================================================
    // CALCULAR CUÁNTA MORA YA FUE PAGADA
    // ==========================================================

    final moraActual = pesosEnteros(
      cuota.mora,
    );

    final moraPendienteActual = pesosEnteros(
      cuota.moraPendiente,
    );

    final moraYaPagada = pesosEnteros(
      moraActual -
          moraPendienteActual,
    );

    // ==========================================================
    // CALCULAR MORA REALMENTE PENDIENTE
    // ==========================================================

    double moraPendiente = pesosEnteros(
      moraTotal -
          moraYaPagada,
    );

    if (moraPendiente < 0) {
      moraPendiente = 0;
    }

    // ==========================================================
    // SI NO HAY MORA PENDIENTE, NO LA MOSTRAMOS
    // ==========================================================

    if (moraPendiente <= 0) {
      continue;
    }

    // ==========================================================
    // DEVOLVER LA CUOTA CON LA MORA ACTUALIZADA
    //
    // No necesariamente la guardamos en BD todavía.
    // La actualizamos en memoria para mostrar el valor real.
    // ==========================================================

    cuotasConMora.add(
      CuotaModel(
        id: cuota.id,

        creditoId: cuota.creditoId,

        numero: cuota.numero,

        capital: pesosEnteros(
          cuota.capital,
        ),

        capitalPendiente: capitalPendiente,

        interes: pesosEnteros(
          cuota.interes,
        ),

        interesPendiente: interesPendiente,

        mora: moraTotal,

        moraPendiente: moraPendiente,

        valorCuota: pesosEnteros(
          cuota.valorCuota,
        ),

        saldoPendiente: pesosEnteros(
          capitalPendiente +
              interesPendiente +
              moraPendiente,
        ),

        totalPagado: pesosEnteros(
          cuota.totalPagado,
        ),

        fechaVencimiento:
            cuota.fechaVencimiento,

        estado: cuota.estado,

        createdAt: cuota.createdAt,
      ),
    );
  }

  return cuotasConMora;
}

  // ============================================================
  // TOTAL DE MORAS ACUMULADAS
  // ============================================================

  Future<double> obtenerTotalMorasAcumuladas(
    String creditoId,
  ) async {
    final cuotas =
        await obtenerCuotasConMoraPendiente(
      creditoId,
    );

    double total = 0;

    for (final cuota in cuotas) {
      total += pesosEnteros(
        cuota.moraPendiente,
      );
    }

    return pesosEnteros(total);
  }

  // ============================================================
  // PAGAR MORAS ACUMULADAS
  //
  // ORDEN:
  // CUOTA MÁS ANTIGUA → CUOTA MÁS RECIENTE
  //
  // ESTE MÉTODO SOLO PAGA MORA.
  // ============================================================

  Future<void> procesarPagoMoras({
    required String creditoId,
    required PagoModel pago,
    required String nombreCliente,
  }) async {
    double restante = pesosEnteros(
      pago.valorPagado,
    );

    if (restante <= 0) {
      throw Exception(
        'El valor del pago debe ser mayor que cero.',
      );
    }

    // ============================================================
    // OBTENER CUOTAS CON MORA
    // ============================================================

    final cuotas =
        await obtenerCuotasConMoraPendiente(
      creditoId,
    );

    if (cuotas.isEmpty) {
      throw Exception(
        'No existen moras pendientes para este crédito.',
      );
    }

    // ============================================================
    // CALCULAR TOTAL DISPONIBLE
    // ============================================================

    double totalMoras = 0;

    for (final cuota in cuotas) {
      totalMoras += pesosEnteros(
        cuota.moraPendiente,
      );
    }

    totalMoras = pesosEnteros(
      totalMoras,
    );

    // ============================================================
    // NO PERMITIR PAGAR MÁS DE LAS MORAS
    // ============================================================

    if (restante > totalMoras) {
      throw Exception(
        'El valor máximo para pagar moras es '
        '\$${totalMoras.toStringAsFixed(0)}.',
      );
    }

    // ============================================================
    // DISTRIBUIR EL PAGO
    // ============================================================

    for (final cuota in cuotas) {
      if (restante <= 0) {
        break;
      }

      double moraPendiente = pesosEnteros(
        cuota.moraPendiente,
      );

      if (moraPendiente <= 0) {
        continue;
      }

      final abono = restante >= moraPendiente
          ? moraPendiente
          : restante;

      moraPendiente = pesosEnteros(
        moraPendiente - abono,
      );

      restante = pesosEnteros(
        restante - abono,
      );

      // ==========================================================
      // MORA TOTAL
      //
      // cuota.mora representa toda la mora generada.
      // No la reducimos; solamente reducimos lo pendiente.
      // ==========================================================

      final moraTotal = pesosEnteros(
        cuota.mora,
      );

      // ==========================================================
      // SALDO PENDIENTE
      // ==========================================================

      final capitalPendiente = pesosEnteros(
        cuota.capitalPendiente,
      );

      final interesPendiente = pesosEnteros(
        cuota.interesPendiente,
      );

      final saldoPendiente = pesosEnteros(
        capitalPendiente +
            interesPendiente +
            moraPendiente,
      );

      // ==========================================================
      // TOTAL PAGADO
      // ==========================================================

      final totalPagado = pesosEnteros(
        cuota.totalPagado +
            abono,
      );

      // ==========================================================
      // ESTADO
      // ==========================================================

      final estado = saldoPendiente == 0
          ? 'pagada'
          : 'pendiente';

      // ==========================================================
      // CUOTA ACTUALIZADA
      // ==========================================================

      final cuotaActualizada = CuotaModel(
        id: cuota.id,

        creditoId: cuota.creditoId,

        numero: cuota.numero,

        capital: pesosEnteros(
          cuota.capital,
        ),

        capitalPendiente:
            capitalPendiente,

        interes: pesosEnteros(
          cuota.interes,
        ),

        interesPendiente:
            interesPendiente,

        mora: moraTotal,

        moraPendiente:
            moraPendiente,

        valorCuota: pesosEnteros(
          cuota.valorCuota,
        ),

        saldoPendiente:
            saldoPendiente,

        totalPagado:
            totalPagado,

        fechaVencimiento:
            cuota.fechaVencimiento,

        estado: estado,

        createdAt: cuota.createdAt,
      );

      // ==========================================================
      // ACTUALIZAR CUOTA
      // ==========================================================

      await supabase
          .from('cuotas')
          .update(
            cuotaActualizada.toUpdateMap(),
          )
          .eq(
            'id',
            cuota.id,
          );

      // ==========================================================
      // REGISTRAR PAGO
      // ==========================================================

      await pagosService.registrarPago(
        pago: PagoModel(
          cuotaId: cuota.id,

          valorPagado: abono,

          capitalPagado: 0,

          interesPagado: 0,

          moraPagada: abono,

          tipoPago: 'mora',

          metodoPago: pago.metodoPago,

          comprobanteUrl:
              pago.comprobanteUrl,

          entidad: pago.entidad,

          observaciones:
              pago.observaciones,

          fechaPago: pago.fechaPago,
        ),
        nombreCliente: nombreCliente,
        numeroCuota: cuota.numero,
      );
    }
  }
}

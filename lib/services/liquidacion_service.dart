import 'package:supabase_flutter/supabase_flutter.dart';

class LiquidacionService {
  final SupabaseClient supabase = Supabase.instance.client;

  /// Devuelve los cobradores activos asignados a una ruta.
  Future<List<Map<String, dynamic>>> obtenerCobradoresPorRuta(
    String rutaId,
  ) async {
    final response = await supabase
        .from('usuario_rutas')
        .select('usuario_id, usuarios!inner(id, nombre, rol, activo)')
        .eq('ruta_id', rutaId);

    final asignaciones = List<Map<String, dynamic>>.from(response);

    return asignaciones
        .map((item) => Map<String, dynamic>.from(item['usuarios'] as Map))
        .where(
          (usuario) =>
              usuario['rol'] == 'cobrador' && usuario['activo'] == true,
        )
        .toList();
  }

  /// Consulta el saldo disponible de la base de la ruta o del cobrador.
  ///
  /// La base de la ruta usa la función SQL calcular_base_disponible para
  /// mantener el mismo cálculo que utiliza la lógica de transferencias.
  /// La base del cobrador se calcula con sus movimientos registrados.
  Future<double> obtenerSaldoBase({
    required String rutaId,
    required String tipoBase,
    String? cobradorId,
  }) async {
    if (tipoBase != 'ruta' && tipoBase != 'cobrador') {
      throw ArgumentError('Tipo de base inválido.');
    }

    if (tipoBase == 'ruta') {
      final response = await supabase.rpc(
        'calcular_base_disponible',
        params: {'p_ruta_id': rutaId},
      );

      if (response is num) {
        return response.toDouble();
      }

      final saldo = double.tryParse(response.toString());
      if (saldo == null) {
        throw StateError('La función de base devolvió un saldo inválido.');
      }

      return saldo;
    }

    if (cobradorId == null || cobradorId.trim().isEmpty) {
      throw ArgumentError(
        'Debes seleccionar un cobrador para consultar su base.',
      );
    }

    final response = await supabase
        .from('movimientos_base')
        .select('tipo_movimiento, monto')
        .eq('ruta_id', rutaId)
        .eq('tipo_base', 'cobrador')
        .eq('cobrador_id', cobradorId);

    double saldo = 0;

    for (final movimiento in List<Map<String, dynamic>>.from(response)) {
      final monto = movimiento['monto'];

      if (monto is! num) {
        throw StateError('Se encontró un movimiento con un monto inválido.');
      }

      if (movimiento['tipo_movimiento'] == 'entrada') {
        saldo += monto.toDouble();
      } else if (movimiento['tipo_movimiento'] == 'salida') {
        saldo -= monto.toDouble();
      }
    }

    return saldo;
  }

  /// Obtiene movimientos de una ruta, opcionalmente filtrados por cobrador,
  /// y agrega el nombre del usuario que registró cada movimiento.
  Future<List<Map<String, dynamic>>> obtenerMovimientos({
    required String rutaId,
    String? cobradorId,
  }) async {
    var consulta = supabase
        .from('movimientos_base')
        .select(
          'id, tipo_base, cobrador_id, tipo_movimiento, '
          'monto, motivo, usuario_id, created_at',
        )
        .eq('ruta_id', rutaId);

    if (cobradorId != null) {
      consulta = consulta.eq('cobrador_id', cobradorId);
    }

    final respuesta = await consulta.order(
      'created_at',
      ascending: false,
    );

    final movimientos = List<Map<String, dynamic>>.from(respuesta);

    final usuariosIds = movimientos
        .map((movimiento) => movimiento['usuario_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList();

    if (usuariosIds.isEmpty) {
      return movimientos
          .map(
            (movimiento) => {
              ...movimiento,
              'nombre_usuario': 'Usuario no disponible',
            },
          )
          .toList();
    }

    final usuariosRespuesta = await supabase
        .from('usuarios')
        .select('id, nombre')
        .inFilter('id', usuariosIds);

    final usuarios = List<Map<String, dynamic>>.from(usuariosRespuesta);
    final nombres = <String, String>{};

    for (final usuario in usuarios) {
      nombres[usuario['id'].toString()] =
          usuario['nombre']?.toString() ?? 'Usuario sin nombre';
    }

    return movimientos.map((movimiento) {
      final usuarioId = movimiento['usuario_id']?.toString();

      return {
        ...movimiento,
        'nombre_usuario': usuarioId == null
            ? 'Usuario no disponible'
            : nombres[usuarioId] ?? 'Usuario no disponible',
      };
    }).toList();
  }

  /// Registra una entrada o salida mediante la función SQL validada.
  Future<void> registrarMovimiento({
    required String rutaId,
    required String tipoBase,
    String? cobradorId,
    required String tipoMovimiento,
    required double monto,
    required String motivo,
  }) async {
    await supabase.rpc(
      'registrar_movimiento_base',
      params: {
        'p_ruta_id': rutaId,
        'p_tipo_base': tipoBase,
        'p_cobrador_id': cobradorId,
        'p_tipo_movimiento': tipoMovimiento,
        'p_monto': monto,
        'p_motivo': motivo.trim(),
      },
    );
  }

  /// Transfiere dinero de la base de ruta a la base de un cobrador.
  Future<void> transferirAlCobrador({
    required String rutaId,
    required String cobradorId,
    required double monto,
    required String motivo,
  }) async {
    await supabase.rpc(
      'transferir_base_cobrador',
      params: {
        'p_ruta_id': rutaId,
        'p_cobrador_id': cobradorId,
        'p_monto': monto,
        'p_motivo': motivo.trim(),
      },
    );
  }
}

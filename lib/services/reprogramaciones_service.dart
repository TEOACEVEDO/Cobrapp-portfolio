import 'package:supabase_flutter/supabase_flutter.dart';

class ReprogramacionesService {
  final supabase = Supabase.instance.client;

  /// Consulta las solicitudes pendientes visibles para el usuario.
  Future<List<Map<String, dynamic>>> obtenerPendientes() async {
    final response = await supabase
        .from('reprogramaciones_pago')
        .select('''
          id,
          cuota_id,
          fecha_original,
          fecha_solicitada,
          motivo,
          solicitado_por,
          created_at
        ''')
        .eq('estado', 'pendiente')
        .order('created_at');

    final solicitudes = List<Map<String, dynamic>>.from(response);

    if (solicitudes.isEmpty) {
      return [];
    }

    // Obtener los datos de las cuotas y sus clientes.
    final ids = solicitudes
        .map((s) => s['cuota_id'] as String)
        .toSet()
        .toList();

    final cuotas = await supabase
        .from('cuotas')
        .select('''
          id,
          numero_cuota,
          valor_cuota,
          creditos(
            clientes(nombre)
          )
        ''')
        .inFilter('id', ids);

    final cuotasPorId = <String, Map<String, dynamic>>{
      for (final cuota in cuotas)
        cuota['id'] as String: Map<String, dynamic>.from(cuota),
    };

    return solicitudes.map((solicitud) {
      final cuota = cuotasPorId[solicitud['cuota_id']];

      return {
        ...solicitud,
        'cuota': cuota,
      };
    }).toList();
  }

  /// Aprueba o rechaza una solicitud.
  Future<void> resolver({
    required String solicitudId,
    required bool aprobar,
    String? observaciones,
  }) async {
    await supabase.rpc(
      'resolver_reprogramacion',
      params: {
        'p_solicitud_id': solicitudId,
        'p_aprobar': aprobar,
        'p_observaciones': observaciones,
      },
    );
  }

  /// Número de solicitudes pendientes visibles.
  Future<int> contarPendientes() async {
    final response = await supabase
        .from('reprogramaciones_pago')
        .select('id')
        .eq('estado', 'pendiente');

    return (response as List).length;
  }
}

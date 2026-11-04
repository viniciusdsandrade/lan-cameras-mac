import Foundation

/// O ponto de vigia: onde a câmera fica parada e para onde o rastreio automático a devolve depois de perder o
/// movimento (`Detect.DetectTrack.ReturnTime` segundos depois). O firmware o guarda como a posição salva 100,
/// gravada com o `SetPreset` do `OPPTZControl` na vista em que a câmera estiver; o app do fabricante chama de
/// "posição de guarda". Sem ela (a XM232 vem assim), a câmera fica onde o rastreio a largou.
extension DVRIPClient {
    static let msgPTZ = 1400
    /// A posição salva que é o ponto de vigia.
    public static let posicaoDeVigia = 100
    /// Posições que o firmware usa para si: o app não cria, não apaga e não oferece nenhuma delas.
    public static let posicoesDoFirmware: Set<Int> = [99, 100, 128, 250]
    /// Os tempos de volta ao ponto de vigia que o app do fabricante oferece, em segundos.
    public static let temposDeVolta = [3, 5, 10, 15, 30, 60, 180, 300, 600, 900, 1800]

    /// Grava a vista atual da câmera numa posição salva.
    func salvarPosicao(_ numero: Int, nome: String = "") throws {
        let r = try pedir(Self.msgPTZ, ["Name": "OPPTZControl", "SessionID": sessaoTexto,
                                        "OPPTZControl": ["Command": "SetPreset",
                                                         "Parameter": ["Channel": 0, "Preset": numero, "PresetName": nome]]])
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret) else {
            throw DVRIPErro("a câmera não guardou a posição (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
    }

    /// Os números das posições salvas na câmera (`Uart.PTZPreset`).
    func posicoesSalvas() throws -> [Int] {
        let valor = try configuracaoComoVeio("Uart.PTZPreset")
        let canais = (valor as? [[[String: Any]]]) ?? ((valor as? [[String: Any]]).map { [$0] } ?? [])
        return (canais.first ?? []).compactMap { CartaoDaCamera.numero($0["Id"]) }
    }
}

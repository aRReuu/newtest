//
//  ImBaseProtocol.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 7/24/25.
//


enum BaseActionResult
{
    case refreshUI
    case errorOccurred(_ error: Swift.Error)
    case isLoading(_ isLoading:Bool = true)
    case success(_ content: String)
    //
    // 协议专属扩展点
    case protocolSpecific(SubProtocolActionResult)
}

/// 子协议下的自定义枚举扩充
enum SubProtocolActionResult
{
    // ImCardViewModelProtocol
    case card(CardActionResult)
    // ImpressNotesViewModelProtocol
    case note(NotesCoordinateResult)
}

/// 基础协议
protocol ImBaseProtocol
{
    /// 统一回调闭包
    var onDataUpdate: ((BaseActionResult) -> Void)? { get set }
}


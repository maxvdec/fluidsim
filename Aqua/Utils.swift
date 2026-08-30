//
//  Utils.swift
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

import Metal

class MTLSyncBuffer<T> {
    private var array: [T]
    private var buffer: MTLBuffer!
    private let device: MTLDevice
    
    var count: Int {
        array.count
    }
    
    init(device: MTLDevice, values: [T] = []) {
        array = values
        self.device = device
        
        remakeBuffer()
    }
    
    func syncListToBuffer() {
        _ = array.withUnsafeBytes { bytes in
            memcpy(buffer.contents(), bytes.baseAddress!, bytes.count)
        }
    }
    
    func syncBufferToList() {
        let count = array.count
        let ptr = buffer.contents().bindMemory(to: T.self, capacity: count)
        array = Array(UnsafeBufferPointer(start: ptr, count: count))
    }
    
    private func syncElementToBuffer(_ index: Int) {
        let destination = buffer.contents()
            .advanced(by: index * MemoryLayout<T>.stride)

        _ = withUnsafePointer(to: &array[index]) { source in
            memcpy(
                destination,
                source,
                MemoryLayout<T>.stride
            )
        }
    }
    
    func remakeBuffer() {
        let size = MemoryLayout<T>.stride * array.count
        
        guard size > 0 else {
            fatalError("Cannot create a zero-length pointer")
        }
        
        buffer = device.makeBuffer(bytes: array, length: size, options: .storageModeShared)
    }
    
    subscript(index: Int) -> T {
        get {
            array[index]
        }
        
        set {
            array[index] = newValue
            syncElementToBuffer(index)
        }
        
        _modify {
            defer {
                syncElementToBuffer(index)
            }
            
            yield &array[index]
        }
    }
    
    func append(_ newElement: T) {
        array.append(newElement)
        remakeBuffer()
    }
    
    func removeAll() {
        array.removeAll()
        remakeBuffer()
    }
    
    func assign(new: [T]) {
        array = new
        remakeBuffer()
    }
    
    func setAtEncoder(_ encoder: MTLComputeCommandEncoder, index: Int) {
        encoder.setBuffer(buffer, offset: 0, index: index)
    }

    func addBarrier(to encoder: MTLComputeCommandEncoder) {
        encoder.memoryBarrier(resources: [buffer])
    }
    
    func setAtVertexBuffer(_ encoder: MTLRenderCommandEncoder, index: Int) {
        encoder.setVertexBuffer(buffer, offset: 0, index: index)
    }
    
    @available(*, deprecated, message: "Try not to access internal arrays or buffers")
    func getArray() -> [T] {
        return array
    }
    
    @available(*, deprecated, message: "Try not to access internal arrays or buffers")
    func getBuffer() -> MTLBuffer {
        return buffer
    }
}

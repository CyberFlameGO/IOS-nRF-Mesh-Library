//
//  FoundationLayer.swift
//  nRFMeshProvision
//
//  Created by Aleksander Nowakowski on 01/07/2019.
//

import Foundation

internal class FoundationLayer {
    let networkManager: NetworkManager
    
    var requests: [Address : ConfigMessage]
    
    init(_ networkManager: NetworkManager) {
        self.networkManager = networkManager
        self.requests = [:]
    }
    
    /// This method handles the received Config Message, depending on its type.
    ///
    /// - parameter configMessage: The Mesh Message received.
    /// - parameter source:        The Unicast Address of the Node that has sent the
    ///                            message.
    func handle(configMessage: ConfigMessage, from source: Address) {
        guard let meshNetwork = networkManager.meshNetwork else {
            return
        }
        
        switch configMessage {
            
        // Composition Data
        case is ConfigCompositionDataGet:
            if let node = meshNetwork.localProvisioner?.node {
                let compositionData = Page0(node: node)
                networkManager.send(ConfigCompositionDataStatus(report: compositionData), to: source)
            }
            
        case let compositionData as ConfigCompositionDataStatus:
            if let node = meshNetwork.node(withAddress: source) {
                node.apply(compositionData: compositionData)
                save()
            }

        // Network Keys Management
        case let request as ConfigNetKeyAdd:
            let keyIndex = request.networkKeyIndex
            do {
                // Make sure the key with given index didn't exist or was identical to the
                // one in the request. Otherwise, return .keyIndexAlreadyStored.
                var networkKey = meshNetwork.networkKeys[keyIndex]
                guard networkKey == nil || networkKey!.key == request.key else {
                    networkManager.send(ConfigNetKeyStatus(report: .keyIndexAlreadyStored, forKeyWithIndex: keyIndex), to: source)
                    break
                }
                if networkKey == nil {
                    networkKey = try meshNetwork.add(networkKey: request.key, withIndex: keyIndex,
                                                     name: "Network Key \(keyIndex + 1)")
                }
                // Add the Network Key index to the local Node.
                if let node = meshNetwork.localProvisioner?.node {
                    node.add(networkKeyWithIndex: keyIndex)
                }
                save()
                networkManager.send(ConfigNetKeyStatus(confirm: networkKey!), to: source)
            } catch {
                networkManager.send(ConfigNetKeyStatus(report: .unspecifiedError, forKeyWithIndex: keyIndex), to: source)
            }
            
        case let request as ConfigNetKeyUpdate:
            let keyIndex = request.networkKeyIndex
            // If there is no such key, return .invalidNetKeyIndex.
            guard let networkKey = meshNetwork.networkKeys[keyIndex] else {
                networkManager.send(ConfigNetKeyStatus(report: .invalidNetKeyIndex, forKeyWithIndex: keyIndex), to: source)
                break
            }
            // Update the key data (observer will set the `oldKey` automatically).
            networkKey.key = request.key
            // And mark the key in the local Node as updated.
            if let node = meshNetwork.localProvisioner?.node {
                node.update(networkKeyWithIndex: keyIndex)
            }
            save()
            networkManager.send(ConfigNetKeyStatus(confirm: networkKey), to: source)
            
        case let request as ConfigNetKeyDelete:
            let keyIndex = request.networkKeyIndex
            // Force delete the key from the global configuration.
            try? meshNetwork.remove(networkKeyWithKeyIndex: keyIndex, force: true)
            // Remove the key also from the local Node. This will also remove all
            // Application Keys bound to it.
            if let node = meshNetwork.localProvisioner?.node {
                node.remove(networkKeyWithIndex: keyIndex)
            }
            save()
            networkManager.send(ConfigNetKeyStatus(report: .success, forKeyWithIndex: keyIndex), to: source)
            
        case let netKeyStatus as ConfigNetKeyStatus:
            if netKeyStatus.isSuccess, let node = meshNetwork.node(withAddress: source) {
                switch requests[source] {
                case is ConfigNetKeyAdd:
                    guard node.netKeys[netKeyStatus.networkKeyIndex] == nil else {
                        break
                    }
                    node.netKeys.append(Node.NodeKey(index: netKeyStatus.networkKeyIndex, updated: false))
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigNetKeyUpdate:
                    guard let netKey = node.netKeys[netKeyStatus.networkKeyIndex] else {
                        break
                    }
                    netKey.updated = true
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigNetKeyDelete:
                    node.remove(networkKeyWithIndex: netKeyStatus.networkKeyIndex)
                    save()
                    requests.removeValue(forKey: source)
                default:
                    break
                }
            }
            
        case is ConfigNetKeyGet:
            networkManager.send(ConfigNetKeyList(networkKeys: meshNetwork.networkKeys), to: source)
            
        case let list as ConfigNetKeyList:
            if let node = meshNetwork.node(withAddress: source) {
                node.netKeys = list.networkKeyIndexs
                    .map({ Node.NodeKey(index: $0, updated: false) })
                    .sorted()
                save()
            }
            
        case let appKeyStatus as ConfigAppKeyStatus:
            if appKeyStatus.isSuccess, let node = meshNetwork.node(withAddress: source) {
                switch requests[source] {
                case is ConfigAppKeyAdd:
                    guard node.appKeys[appKeyStatus.applicationKeyIndex] == nil else {
                        break
                    }
                    node.appKeys.append(Node.NodeKey(index: appKeyStatus.applicationKeyIndex, updated: false))
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigAppKeyUpdate:
                    guard let appKey = node.appKeys[appKeyStatus.applicationKeyIndex] else {
                        break
                    }
                    appKey.updated = true
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigAppKeyDelete:
                    node.remove(applicationKeyWithIndex: appKeyStatus.applicationKeyIndex)
                    save()
                    requests.removeValue(forKey: source)
                default:
                    break
                }
            }
            
        case let list as ConfigAppKeyList:
            if let node = meshNetwork.node(withAddress: source) {
                // Leave only those App Keys, that are bound to a different Network Key than in the
                // received response.
                node.appKeys = node.appKeys.filter {
                    node.applicationKeys[$0.index]?.boundNetworkKeyIndex != list.networkKeyIndex
                }
                node.appKeys.append(contentsOf: list.applicationKeyIndexes.map({ Node.NodeKey(index: $0, updated: false) }))
                node.appKeys.sort()
                save()
            }
            
        case let status as ConfigModelAppStatus:
            if status.isSuccess,
                let node = meshNetwork.node(withAddress: source),
                let element = node.element(withAddress: status.elementAddress),
                let model = element.model(withModelId: status.modelId) {
                switch requests[source] {
                case is ConfigModelAppBind:
                    model.bind(applicationKeyWithIndex: status.applicationKeyIndex)
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigModelAppUnbind:
                    model.unbind(applicationKeyWithIndex: status.applicationKeyIndex)
                    save()
                    requests.removeValue(forKey: source)
                default:
                    break
                }
            }
            
        case let list as ConfigModelAppList:
            if list.isSuccess,
                let node = meshNetwork.node(withAddress: source),
                let element = node.element(withAddress: list.elementAddress),
                let model = element.model(withModelId: list.modelId) {
                // Replace the known binding with what was received in the message.
                model.bind = list.applicationKeyIndexes.sorted()
                save()
            }
            
        case let status as ConfigModelPublicationStatus:
            if status.isSuccess,
                let node = meshNetwork.node(withAddress: source),
                let element = node.element(withAddress: status.elementAddress),
                let model = element.model(withModelId: status.modelId) {
                switch requests[source] {
                case is ConfigModelPublicationSet:
                    if !status.publish.publicationAddress.address.isUnassigned {
                        model.publish = status.publish
                    } else {
                        // An unassigned Address is sent to remove the publication.
                        model.publish = nil
                    }
                    save()
                    requests.removeValue(forKey: source)
                case let request as ConfigModelPublicationVirtualAddressSet:
                    // Note: The Publish from the request has the Virtual Label set,
                    //       while the status has only the 16-bit Virtual Address.
                    // Note: We assume here, that the response is identical to the
                    //       request, with an exception of the Virtual Label.
                    model.publish = request.publish
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigModelPublicationGet:
                    let publicationAddress = status.publish.publicationAddress
                    if publicationAddress.address.isUnassigned {
                        model.publish = nil
                    } else if publicationAddress.address.isVirtual {
                        // The received status message is missing the Virtual Label.
                        // Let's try to find it in the local groups.
                        if let group = meshNetwork.group(withAddress: publicationAddress),
                            let _ = group.address.virtualLabel {
                            // A Group with the same address and non-nil Virtual Label has been found.
                            model.publish = status.publish.withAddress(address: group.address)
                        } else {
                            // The Model is publishing to an unknown Virtual Label.
                            // The label will remain `nil`, but it's virtual address is known.
                            model.publish = status.publish
                        }
                    } else {
                        model.publish = status.publish
                    }
                    save()
                    requests.removeValue(forKey: source)
                default:
                    break
                }
            }
            
        case let status as ConfigModelSubscriptionStatus:
            if status.isSuccess,
                let node = meshNetwork.node(withAddress: source),
                let element = node.element(withAddress: status.elementAddress),
                let model = element.model(withModelId: status.modelId) {
                let address = MeshAddress(status.address)
                
                // The status for Delete All request has an invalid address.
                // Handle it differently here.
                if let _ = requests[source] as? ConfigModelSubscriptionDeleteAll {
                    model.subscribe.removeAll()
                    save()
                    requests.removeValue(forKey: source)
                }
                // Here it should be safe to search for the group.
                guard let group = meshNetwork.group(withAddress: address) else {
                    requests.removeValue(forKey: source)
                    return
                }
                switch requests[source] {
                case is ConfigModelSubscriptionOverwrite, is ConfigModelSubscriptionVirtualAddressOverwrite:
                    model.subscribe.removeAll()
                    fallthrough
                case is ConfigModelSubscriptionAdd, is ConfigModelSubscriptionVirtualAddressAdd:
                    model.subscribe(to: group)
                    save()
                    requests.removeValue(forKey: source)
                case is ConfigModelSubscriptionDelete, is ConfigModelSubscriptionVirtualAddressDelete:
                    model.unsubscribe(from: group)
                    save()
                    requests.removeValue(forKey: source)
                default:
                    break
                }
            }
            
        case let list as ConfigModelSubscriptionList:
            if list.isSuccess,
                let node = meshNetwork.node(withAddress: source),
                let element = node.element(withAddress: list.elementAddress),
                let model = element.model(withModelId: list.modelId) {
                model.subscribe.removeAll()
                for address in list.addresses {
                    if let group = meshNetwork.groups.first(where: { $0.address.address == address }) {
                        model.subscribe.append(group.address.hex)
                    } else {
                        model.subscribe.append(address.hex)
                    }
                }
                save()
            }
            
        case let request as ConfigDefaultTtlSet:
            if let node = meshNetwork.localProvisioner?.node {
                node.defaultTTL = request.ttl
                save()
                networkManager.send(ConfigDefaultTtlStatus(ttl: node.defaultTTL ?? LowerTransportLayer.defaultTtl), to: source)
            }
            
        case is ConfigDefaultTtlGet:
            if let node = meshNetwork.localProvisioner?.node {
                networkManager.send(ConfigDefaultTtlStatus(ttl: node.defaultTTL ?? LowerTransportLayer.defaultTtl), to: source)
            }
            
        case let defaultTtl as ConfigDefaultTtlStatus:
            if let node = meshNetwork.node(withAddress: source) {
                node.ttl = defaultTtl.ttl
                save()
            }
            
        case is ConfigNodeResetStatus:
            if let node = meshNetwork.node(withAddress: source) {
                meshNetwork.remove(node: node)
                save()
            }
            
        default:
            break
        }
    }
    
    /// This method handles the Mesh Message that is about to being sent,
    /// depending on its type.
    ///
    /// - parameter configMessage: The Mesh Message to be sent.
    /// - parameter destination:   The Unicast Address of the target Node.
    /// - returns: `True`, if the message can be send, otherwise `false`.
    func handle(configMessage: ConfigMessage, to destination: Address) -> Bool {
        switch configMessage {
            
        // Those messages are ACK on the Foundation Layer with Config...Status.
        // The action taken upon receiving the status depends on the request.
        case is ConfigNetKeyAdd, is ConfigNetKeyDelete, is ConfigNetKeyUpdate:
            requests[destination] = configMessage
                
        case is ConfigAppKeyAdd, is ConfigAppKeyDelete, is ConfigAppKeyUpdate:
            requests[destination] = configMessage
            
        case is ConfigModelAppBind, is ConfigModelAppUnbind:
            requests[destination] = configMessage
            
        case is ConfigModelPublicationSet, is ConfigModelPublicationVirtualAddressSet, is ConfigModelPublicationGet:
            requests[destination] = configMessage
            
        case is ConfigModelSubscriptionAdd, is ConfigModelSubscriptionDelete, is ConfigModelSubscriptionDeleteAll,
             is ConfigModelSubscriptionOverwrite, is ConfigModelSubscriptionVirtualAddressAdd,
             is ConfigModelSubscriptionVirtualAddressDelete, is ConfigModelSubscriptionVirtualAddressOverwrite:
            requests[destination] = configMessage
            
        default:
            break
        }
        return true
    }
}

private extension FoundationLayer {
    
    /// Save the state of the mesh network to the storage associated with
    /// the manager. This method ignores the result of saving.
    private func save() {
        _ = networkManager.meshNetworkManager.save()
    }
    
}

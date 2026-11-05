//
//  ImBaseTableViewCell.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 1/12/23.
//  公用属性

import UIKit

class ImBaseTableViewCell: UITableViewCell
{
    var copyText:String?
    

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?)
    {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // public properties
        backgroundColor = tableViewBGColor
        selectionStyle = .none
        textLabel?.textColor = titleColor
        textLabel?.numberOfLines = 3
        detailTextLabel?.textColor = subTitleColor
        detailTextLabel?.numberOfLines = 0
        textLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
    
}

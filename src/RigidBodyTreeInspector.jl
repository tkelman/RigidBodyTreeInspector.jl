module RigidBodyTreeInspector

using RigidBodyDynamics
import Quaternions: axis, angle, qrotation, rotationmatrix, Quaternion
import DrakeVisualizer: Visualizer, draw, Link, GeometryData, HyperEllipsoid, HyperCylinder
import FixedSizeArrays: Vec, Point
import AffineTransforms: AffineTransform, tformrotate, tformtranslate, tformeye
import GeometryTypes: AbstractGeometry, HyperRectangle, HyperSphere
import DataStructures: OrderedDict
import ColorTypes: RGBA
import Interact
import Interpolations: interpolate, Linear, Gridded
import Base: convert, one
import LightXML: XMLElement, parse_file, root, get_elements_by_tagname, attribute, find_element, name
import MeshIO
using FileIO

export create_geometry, inspect, Visualizer, draw, animate, parse_urdf

function rotation_from_x_axis{T}(translation::Vec{3, T})
    xhat = Vec{3, T}(1, 0, 0)
    v = translation / norm(translation)
    costheta = dot(xhat, v)
    p = cross(xhat, v)
    sintheta = norm(p)
    axis = p / sintheta
    angle = atan2(sintheta, costheta)
    return axis, angle
end

function inertial_ellipsoid_dimensions(mass, axis_inertias)
    # Ix = m/5 (dy^2 + dz^2)
    # Iy = m/5 (dx^2 + dz^2)
    # Iz = m/5 (dx^2 + dy^2)
    #
    # let A = [0 1 1
    #          1 0 1
    #          1 1 0]
    # b = 5 / m * [Ix; Iy; Iz]
    # Then A \ b = [dx^2; dy^2; dz^2]
    #
    # This is only valid if the axis inertias obey the triangle inequalities:
    # Ix + Iy >= Iz
    # Ix + Iz >= Iy
    # Iy + Iz >= Ix


    A = [0. 1 1; 1 0 1; 1 1 0]

    for i = 1:3
        if axis_inertias[i] > dot(A[:,i], axis_inertias)[1]
            warn("Principal inertias $(axis_inertias) do not satisfy the triangle inequalities, so the equivalent inertial ellipsoid is not well-defined.")
        end
    end

    squared_lengths = A \ (5. / mass * axis_inertias)

    # If the triangle inequality was violated, we'll get negative squared lengths.
    # Instead, just make them very small so we can try to do something reasonable.
    for (i, l) in enumerate(squared_lengths)
        if l < 0
            squared_lengths[i] = 0.01 * maximum(squared_lengths)
        end
    end
    return √(squared_lengths)
end

function inertial_ellipsoid(body)
    com_frame = CartesianFrame3D("com")
    com_to_body = Transform3D(com_frame, body.frame, body.inertia.centerOfMass)
    spatial_inertia = transform(body.inertia, inv(com_to_body))
    e = eigfact(convert(Array, spatial_inertia.moment))
    principal_inertias = e.values
    axes = e.vectors
    radii = inertial_ellipsoid_dimensions(spatial_inertia.mass, principal_inertias)
    geometry = HyperEllipsoid{3, Float64}(zero(Point{3, Float64}), Vec{3, Float64}(radii))
    return geometry, AffineTransform(axes', convert(Vector, body.inertia.centerOfMass))
end

function create_geometry(mechanism; box_width=0.05, show_inertias::Bool=false, randomize_colors::Bool=true)
    vis_data = OrderedDict{RigidBody, Link}()
    for vertex in mechanism.toposortedTree
        if randomize_colors
            color = RGBA{Float64}(rand(3)..., 0.5)
        else
            color = RGBA{Float64}(1, 0, 0, 0.5)
        end
        body = vertex.vertexData
        geometries = Vector{GeometryData}()
        if show_inertias && !isroot(body)
            prism, tform = inertial_ellipsoid(body)
            push!(geometries, GeometryData(prism, tform, color))

            a, theta = rotation_from_x_axis(body.inertia.centerOfMass)
            joint_to_geometry_origin = tformrotate(convert(Vector, a), theta)
            geom_length = norm(body.inertia.centerOfMass)
            push!(geometries, GeometryData(HyperRectangle(Vec(0., -box_width/4, -box_width/4), Vec(geom_length, box_width/2, box_width/2)), joint_to_geometry_origin, color))
        else
            push!(geometries, GeometryData(HyperRectangle(Vec{3, Float64}(-box_width), Vec{3, Float64}(box_width * 2)), tformeye(3), color))
        end
        if !isroot(body)
            for child in vertex.children
                joint = child.edgeToParentData
                joint_to_joint = mechanism.jointToJointTransforms[joint]
                a, theta = rotation_from_x_axis(joint_to_joint.trans)
                joint_to_geometry_origin = tformrotate(convert(Vector, a), theta)
                geom_length = norm(joint_to_joint.trans)
                push!(geometries, GeometryData(HyperRectangle(Vec(0., -box_width/2, -box_width/2), Vec(geom_length, box_width, box_width)), joint_to_geometry_origin, color))
            end
        end
        vis_data[body] = Link(geometries, body.frame.name)
    end
    vis_data
end

function Visualizer(mechanism::Mechanism; show_inertias::Bool=false, randomize_colors::Bool=true)
    vis_data = create_geometry(mechanism; show_inertias=show_inertias, randomize_colors=randomize_colors)
    Visualizer(collect(values(vis_data)))
end

convert(::Type{AffineTransform}, T::Transform3D) = tformtranslate(convert(Vector, T.trans)) * tformrotate(axis(T.rot), angle(T.rot))

function draw(vis::Visualizer, state::MechanismState)
    bodies = [v.vertexData for v in state.mechanism.toposortedTree]
    origin_transforms = map(body -> convert(AffineTransform, transform_to_root(state, RigidBodyDynamics.default_frame(state.mechanism, body))), bodies)
    draw(vis, origin_transforms)
end

function joint_configuration{T}(jointType::RigidBodyDynamics.QuaternionFloating, sliders::NTuple{6, T})
    q = collect(sliders)
    quat = qrotation(q[1:3])

    vcat([quat.s; quat.v1; quat.v2; quat.v3], q[4:6])
end
joint_configuration{T}(jointType::RigidBodyDynamics.OneDegreeOfFreedomFixedAxis, sliders::NTuple{1, T}) = collect(sliders)
joint_configuration(jointType::RigidBodyDynamics.Fixed, sliders::Tuple{}) = []
num_sliders(jointType::RigidBodyDynamics.OneDegreeOfFreedomFixedAxis) = 1
num_sliders(jointType::RigidBodyDynamics.QuaternionFloating) = 6
num_sliders(jointType::RigidBodyDynamics.Fixed) = 0
num_sliders(joint::RigidBodyDynamics.Joint) = num_sliders(joint.jointType)

function inspect(mechanism, vis::Visualizer=nothing; show_inertias::Bool=false, randomize_colors::Bool=true)
    if vis == nothing
        vis = Visualizer(mechanism; show_inertias=show_inertias, randomize_colors=randomize_colors)
    end
    state = MechanismState(Float64, mechanism)
    mech_joints = [v.edgeToParentData for v in mechanism.toposortedTree[2:end]]
    num_sliders_per_joint = map(num_sliders, mech_joints)
    slider_names = ASCIIString[]
    for (i, joint) in enumerate(mech_joints)
        for j in 1:num_sliders_per_joint[i]
            push!(slider_names, "$(joint.name).$(j)")
        end
    end
    widgets = [Interact.widget(linspace(-pi, pi, 51), slider_names[i]) for i = 1:sum(num_sliders_per_joint)]
    map(display, widgets)
    map((q...) -> begin
        slider_index = 1
        for (i, joint) in enumerate(mech_joints)
            state.q[joint][:] = joint_configuration(joint.jointType, q[slider_index:(slider_index+num_sliders_per_joint[i]-1)])
            slider_index += num_sliders_per_joint[i]
        end
        setdirty!(state)
        draw(vis, state)
        end, [Interact.signal(w) for w in widgets]...)
end

one(::Type{Array{Float64,1}}) = 1.

function animate(vis::Visualizer, mechanism::Mechanism{Float64}, times::Vector{Float64}, configurations::Vector{Vector{Float64}};
    fps::Float64 = 30., realtimerate::Float64 = 1.)
    state = MechanismState(Float64, mechanism)
    dt = 1. / fps
    interpolated_configurations = interpolate((times,), configurations, Gridded(Linear()))
    for t in times[1] : dt : times[end]
        tic()
        set_configuration!(state, interpolated_configurations[t])
        RigidBodyTreeInspector.draw(vis, state)
        sleep(max(dt - toq(), 0) / realtimerate)
    end
end

animate(mechanism::Mechanism, times::Vector{Float64}, configurations::Vector{Vector{Float64}}) = animate(Visualizer(mechanism), mechanism, times, configurations)

include("parse_urdf.jl")

end
